import Foundation

@MainActor
final class DevinProvider: ProviderRuntime {
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    let authStore: DevinAuthStore
    let usageClient: DevinUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        usageClient: DevinUsageClient = DevinUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota"),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // A proven miss across both sources is absent. Any read/parse failure counts conservatively so
        // one-shot detection enables Devin and `refresh()` can show the repairable error.
        do {
            if try await loadOffMainActor({ [authStore] in try authStore.loadCredentialsFile() }) != nil {
                return true
            }
        } catch {
            logUnexpectedProbeError(error, source: "CLI credential file")
            return true
        }
        do {
            return try await loadOffMainActor { [authStore] in try authStore.loadAppAuth() } != nil
        } catch {
            logUnexpectedProbeError(error, source: "app credential database")
            return true
        }
    }

    func refresh() async -> ProviderSnapshot {
        var sawAPIKey = false
        var sawAuthFailure = false
        var firstLoadError: DevinAuthError?
        let credentials: DevinAuth?
        do {
            credentials = try await loadOffMainActor { [authStore] in try authStore.loadCredentialsFile() }
        } catch {
            firstLoadError = loadError(error, source: "CLI credential file")
            credentials = nil
        }

        if let credentials {
            sawAPIKey = true
            switch await attempt(auth: credentials) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        let appAuth: DevinAuth?
        do {
            appAuth = try await loadOffMainActor { [authStore] in try authStore.loadAppAuth() }
        } catch {
            if firstLoadError == nil {
                firstLoadError = loadError(error, source: "app credential database")
            }
            appAuth = nil
        }
        if let appAuth,
           credentials == nil || shouldAttemptAppAuth(appAuth, after: credentials) {
            sawAPIKey = true
            switch await attempt(auth: appAuth) {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .unavailable:
                break
            }
        }

        if sawAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
        }
        if sawAPIKey {
            return ProviderSnapshot.error(provider: provider, error: DevinUsageError.quotaUnavailable)
        }
        if let firstLoadError {
            return ProviderSnapshot.error(provider: provider, error: firstLoadError)
        }
        return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
    }

    private func attempt(auth: DevinAuth) async -> DevinAuthAttempt {
        let apiServerURL = authStore.effectiveAPIServerURL(auth)
        do {
            let response = try await usageClient.fetchUserStatus(auth: auth, apiServerURL: apiServerURL)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authFailure
            }
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable
            }
            return .success(try DevinUsageMapper.mapUserStatusResponse(response))
        } catch {
            return .unavailable
        }
    }

    private func shouldAttemptAppAuth(_ appAuth: DevinAuth, after credentials: DevinAuth?) -> Bool {
        guard let credentials else { return true }
        return appAuth.apiKey != credentials.apiKey ||
            authStore.effectiveAPIServerURL(appAuth) != authStore.effectiveAPIServerURL(credentials)
    }

    private func snapshot(from mapped: DevinMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }

    private func loadError(_ error: Error, source: String) -> DevinAuthError {
        if let authError = error as? DevinAuthError { return authError }
        AppLog.error(LogTag.auth("devin"), "unexpected \(source) failure: \(error.localizedDescription)")
        return .credentialStoreUnreadable
    }

    private func logUnexpectedProbeError(_ error: Error, source: String) {
        guard !(error is DevinAuthError) else { return }
        AppLog.error(LogTag.auth("devin"), "unexpected \(source) probe failure: \(error.localizedDescription)")
    }
}

private enum DevinAuthAttempt {
    case success(DevinMappedUsage)
    case authFailure
    case unavailable
}
