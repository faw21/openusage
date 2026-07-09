import Foundation

@MainActor
final class GrokProvider: ProviderRuntime {
    let provider = Provider(
        id: "grok",
        displayName: "Grok",
        icon: .providerMark("grok"),
        links: [
            .init(label: "Usage", url: "https://grok.com/?_s=usage")
        ]
    )

    let authStore: GrokAuthStore
    let usageClient: GrokUsageClient
    let logUsageScanner: GrokLogUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: GrokAuthStore = GrokAuthStore(),
        usageClient: GrokUsageClient = GrokUsageClient(),
        logUsageScanner: GrokLogUsageScanner = GrokLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "grok.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly limit"),
            .badge(id: "grok.payAsYouGo", provider: provider, title: "Extra Usage", metricLabel: "Pay as you go"),
            .usageTrend(provider: provider)
            // Local spend tiles, estimated from the Grok CLI log (see GrokLogUsageScanner).
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: ~/.grok/auth.json with at least one keyed entry.
        await loadOffMainActor { [authStore] in
            ((try? authStore.loadAuthCandidates()) ?? []).isEmpty == false
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndProbe()
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadAndProbe() async throws -> ProviderSnapshot {
        let candidates = try authStore.loadAuthCandidates()
        var sawExpiredCandidate = false
        var refreshFailure: Error?

        for var state in candidates {
            if authStore.needsRefresh(entry: state.entry, token: state.token) {
                let isExpired = authStore.isExpired(entry: state.entry, token: state.token)
                let refreshed: String?
                do {
                    refreshed = try await refreshAccessToken(state: &state)
                } catch {
                    if isExpired {
                        sawExpiredCandidate = true
                        if !(error is GrokAuthError), refreshFailure == nil {
                            refreshFailure = error
                        }
                        continue
                    }
                    // A token inside the refresh buffer is still usable. Preserve that resilience, but
                    // record why the proactive refresh failed before trying the current token.
                    AppLog.warn(LogTag.auth("grok"), "proactive token refresh failed; trying the current unexpired token: \(error.localizedDescription)")
                    refreshed = nil
                }
                if let refreshed {
                    if let snapshot = try await probeCandidate(state: &state, accessToken: refreshed) {
                        return snapshot
                    }
                    sawExpiredCandidate = true
                    continue
                }
                if isExpired {
                    sawExpiredCandidate = true
                    continue
                }
            }
            if let snapshot = try await probeCandidate(state: &state, accessToken: state.token) {
                return snapshot
            }
            sawExpiredCandidate = true
        }

        if let refreshFailure {
            throw refreshFailure
        }
        if sawExpiredCandidate {
            throw GrokAuthError.expired
        }
        throw GrokAuthError.invalidAuth
    }

    /// A rejected token invalidates only this stored account. Keep probing later accounts, while every
    /// non-authentication failure still escapes immediately with its precise network/HTTP/decoding type.
    private func probeCandidate(state: inout GrokAuthState, accessToken: String) async throws -> ProviderSnapshot? {
        do {
            return try await probe(state: &state, accessToken: accessToken)
        } catch is GrokAuthError {
            AppLog.warn(LogTag.auth("grok"), "stored account was rejected; trying the next account if available")
            return nil
        }
    }

    private func probe(state: inout GrokAuthState, accessToken: String) async throws -> ProviderSnapshot {
        // The weekly shared-pool meter and pay-as-you-go badge come from the billing endpoint with
        // `?format=credits` — the call the Grok CLI itself makes. This is the provider's primary
        // remote fetch; a failure here fails the provider like any other usage call.
        let creditsResponse = try await fetchCreditsConfigWithRetry(accessToken: accessToken, state: &state)
        var mapped = try GrokUsageMapper.mapCreditsConfig(creditsResponse)

        let plan = await fetchPlanName(accessToken: state.token)

        // Local spend tiles, read natively from the Grok CLI log and priced via the shared pricing
        // store. `scan` is awaited so its whole-file read + parse runs off the main actor.
        if let scan = await logUsageScanner.scan(daysBack: 30, now: now(), pricing: await pricing()) {
            SpendTileMapper.appendTokenUsage(
                scan.series,
                to: &mapped.lines,
                now: now(),
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: "From your Grok logs (estimated)"
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &mapped.lines, now: now(),
                                             note: "From your Grok logs (estimated)")
        }

        return ProviderSnapshot.make(provider: provider, plan: plan, lines: mapped.lines, refreshedAt: now())
    }

    private func fetchCreditsConfigWithRetry(accessToken: String, state: inout GrokAuthState) async throws -> HTTPResponse {
        var working = state
        defer { state = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchCreditsConfig(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(state: &working) else {
                    throw GrokAuthError.expired
                }
                return refreshed
            },
            connectionFailed: GrokUsageError.connectionFailed,
            authExpired: GrokAuthError.expired
        )
    }

    private func refreshAccessToken(state: inout GrokAuthState) async throws -> String? {
        guard let refreshToken = authStore.refreshToken(for: state.entry) else {
            return nil
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(
                refreshToken,
                clientID: authStore.clientID(entryKey: state.entryKey, entry: state.entry)
            )
        } catch {
            AppLog.warn(LogTag.auth("grok"), "token refresh request failed (transport): \(error.localizedDescription)")
            throw GrokRefreshError.connectionFailed
        }

        if refreshTokenWasRejected(response) {
            AppLog.warn(LogTag.auth("grok"), "token refresh failed (HTTP \(response.statusCode))")
            throw GrokAuthError.expired
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.auth("grok"), "token refresh failed (HTTP \(response.statusCode))")
            throw GrokRefreshError.requestFailed(response.statusCode)
        }

        let decoded: GrokRefreshResponse
        do {
            decoded = try usageClient.decodeRefreshResponse(response)
        } catch {
            AppLog.warn(LogTag.auth("grok"), "token refresh returned an undecodable or empty access token")
            throw GrokRefreshError.invalidResponse
        }
        guard !decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.warn(LogTag.auth("grok"), "token refresh returned an undecodable or empty access token")
            throw GrokRefreshError.invalidResponse
        }

        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt: Date
        do {
            expiresAt = try refreshExpiryDate(response: decoded, accessToken: accessToken)
        } catch {
            AppLog.warn(LogTag.auth("grok"), "token refresh returned invalid expiry metadata")
            throw error
        }

        // Validate the complete refresh payload before mutating in-memory or persisted auth state.
        state.token = accessToken
        state.entry.key = accessToken
        if let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty {
            state.entry.refreshToken = refreshToken
        }
        if let idToken = decoded.idToken?.trimmingCharacters(in: .whitespacesAndNewlines), !idToken.isEmpty {
            state.entry.idToken = idToken
        }

        state.entry.expiresAt = OpenUsageISO8601.string(from: expiresAt)
        // Fail loudly: a swallowed save strands the rotated token on disk (next launch re-refreshes /
        // can surface a false "auth expired"). The refreshed token works for this session, so log and
        // continue rather than fail the live fetch.
        do {
            try authStore.save(state)
        } catch {
            AppLog.error(LogTag.auth("grok"), "failed to persist rotated credentials; using the refreshed token for this session only: \(error.localizedDescription)")
        }
        return accessToken
    }

    private func refreshTokenWasRejected(_ response: HTTPResponse) -> Bool {
        guard (400..<500).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let errorCode = (body["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return errorCode.caseInsensitiveCompare("invalid_grant") == .orderedSame
    }

    private func refreshExpiryDate(response: GrokRefreshResponse, accessToken: String) throws -> Date {
        if let expiresIn = response.expiresIn {
            guard expiresIn.isFinite, expiresIn > 0 else {
                throw GrokRefreshError.invalidResponse
            }
            return now().addingTimeInterval(expiresIn)
        }
        if let tokenExpiry = authStore.tokenExpiresAt(accessToken) {
            return tokenExpiry
        }
        return now().addingTimeInterval(60 * 60)
    }

    private func fetchPlanName(accessToken: String) async -> String? {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchSettings(accessToken: accessToken)
        } catch {
            AppLog.warn(LogTag.plugin("grok"), "optional plan request failed")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(LogTag.plugin("grok"), "optional plan request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let plan = GrokUsageMapper.planName(from: response) else {
            AppLog.warn(LogTag.plugin("grok"), "optional plan response contained invalid plan metadata")
            return nil
        }
        return plan
    }
}
