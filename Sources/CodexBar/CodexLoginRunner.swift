import CodexBarCore
import Foundation

struct CodexLoginRunner {
    struct Result {
        enum Outcome {
            case success
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
    }

    static func run(homePath: String? = nil, timeout: TimeInterval = 120) async -> Result {
        await Task(priority: .userInitiated) {
            let outputFallback = "No output captured."
            do {
                let output = try self.runPTY(homePath: homePath, timeout: timeout)
                let settledOutput = output.isEmpty ? outputFallback : output
                if await self.waitForPersistedCredentials(homePath: homePath) {
                    return Result(outcome: .success, output: settledOutput)
                }
                return Result(
                    outcome: .failed(status: 1),
                    output: settledOutput)
            } catch LoginError.binaryNotFound {
                return Result(outcome: .missingBinary, output: "")
            } catch let LoginError.timedOut(text) {
                return Result(outcome: .timedOut, output: text.isEmpty ? outputFallback : text)
            } catch let LoginError.failed(status, text) {
                let output = text.isEmpty ? "codex login exited with status \(status)." : text
                return Result(outcome: .failed(status: status), output: output)
            } catch let LoginError.launchFailed(message) {
                return Result(outcome: .launchFailed(message), output: "")
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription), output: "")
            }
        }.value
    }

    private enum LoginError: Error {
        case binaryNotFound
        case timedOut(text: String)
        case failed(status: Int32, text: String)
        case launchFailed(String)
    }

    private static func runPTY(homePath: String?, timeout: TimeInterval) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: env,
            loginPATH: LoginShellPathCache.shared.current)
        env = CodexHomeScope.scopedEnvironment(base: env, codexHome: homePath)

        guard let executable = BinaryLocator.resolveCodexBinary(
            env: env,
            loginPATH: LoginShellPathCache.shared.current)
        else {
            throw LoginError.binaryNotFound
        }

        let runner = TTYCommandRunner()
        var options = TTYCommandRunner.Options(rows: 50, cols: 160, timeout: timeout)
        options.extraArgs = ["login"]
        options.baseEnvironment = env
        options.stopOnURL = false
        options.stopOnSubstrings = [
            "Successfully logged in",
            "Login successful",
            "Logged in successfully",
            "You are now logged in",
        ]

        do {
            let result = try runner.run(binary: executable, send: "", options: options)
            return result.text
        } catch TTYCommandRunner.Error.binaryNotFound {
            throw LoginError.binaryNotFound
        } catch TTYCommandRunner.Error.timedOut {
            throw LoginError.timedOut(text: "")
        } catch let TTYCommandRunner.Error.launchFailed(message) {
            throw LoginError.launchFailed(message)
        } catch {
            throw LoginError.launchFailed(error.localizedDescription)
        }
    }

    private static func waitForPersistedCredentials(
        homePath: String?,
        settleTimeout: TimeInterval = 2.0,
        pollInterval: UInt64 = 100_000_000) async -> Bool
    {
        if self.hasPersistedCredentials(homePath: homePath) {
            return true
        }

        let deadline = Date().addingTimeInterval(max(0, settleTimeout))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            if self.hasPersistedCredentials(homePath: homePath) {
                return true
            }
        }
        return self.hasPersistedCredentials(homePath: homePath)
    }

    private static func hasPersistedCredentials(homePath: String?) -> Bool {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        return (try? CodexOAuthCredentialsStore.load(env: env)) != nil
    }
}
