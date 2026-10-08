using System.Diagnostics;
using Nexus.Intelligence.Contracts;
using Nexus.Intelligence.LiveSmokeHost;
using Xunit;

namespace Nexus.Intelligence.LiveSmokeTests;

/// <summary>
/// The three provider-specific smoke checks, re-homed to the AI Head that owns them.
/// </summary>
/// <remarks>
/// <para>
/// These are migration runbook items 12, 13 and 14, carried at the Platform layer until W7G.2 as
/// <c>LiveOpenAIEndToEndTests</c> over <c>samples/Nexus.Platform.SmokeHost</c>. That path was
/// retired as <c>SUPERSEDED_BY_AI_HEAD_PROVIDER_TESTING</c>, and these are its successors — not a
/// rewrite, a re-homing. The checks are the same three because they are the checks the runbook
/// names; what changed is which repository owns them and which composition root they run against.
/// </para>
/// <para>
/// <b>What is genuinely new, stated so it is not oversold.</b> The old suite drove
/// <c>AddNexusPlatform</c> plus a bare provider registration. This one drives
/// <c>AddNexusIntelligence</c> — the AI Head's whole governed path: the capability gateway, the
/// governance evaluator, the registry and router, the operational gates, the operations recorder
/// and the audit sink — with a real vendor at the far end. So each assertion below is now a
/// statement about the estate a product calls rather than about a routing gateway in isolation.
/// That is a stronger claim, and it is the reason re-homing was worth doing rather than merely
/// relocating.
/// </para>
/// <para>
/// <b>Every test fails loudly without a credential rather than passing quietly.</b> There is no
/// runtime skip in xunit v2, and the alternative — a silent pass — is the defect this estate's
/// audit keeps recording. Running this project with no key set produces failures whose message is
/// the instruction for setting one. That is the intended behaviour, and it is why the project is
/// outside the solution: a required-credential suite in the default run would fail every lane.
/// </para>
/// <para>
/// <b>No credential value is read, printed, compared or logged anywhere in this file.</b> The only
/// thing any test learns about the credential is whether one is present
/// (<see cref="LiveProviderKey.Available"/>), and the value is resolved inside the provider adapter
/// by the estate's own neutral resolver.
/// </para>
/// </remarks>
public sealed class LiveProviderSmokeTests
{
    /// <summary>
    /// A prompt with exactly one correct answer, so the assertion is about the model having run and
    /// not about the wording of a reply. The expected token is asserted case-insensitively because a
    /// model is entitled to capitalise.
    /// </summary>
    private const string Prompt = "Reply with exactly the word: pong";

    private const string ExpectedToken = "pong";

    private static void RequireCredential()
    {
        if (!LiveProviderKey.Available())
        {
            Assert.Fail(LiveProviderKey.SkipReason);
        }
    }

    // ============================================================================================
    // Runbook item 12 - chat works end to end.
    // ============================================================================================

    [Fact]
    public async Task LiveProvider_RealTurn_ReturnsModelResponse()
    {
        RequireCredential();

        await using var estate = await LiveEstate.StartAsync();

        var response = await estate.ChatAsync(Prompt);

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);

        Assert.False(
            string.IsNullOrWhiteSpace(response.Output),
            "a live turn must return the model's output");

        Assert.Contains(ExpectedToken, response.Output!, StringComparison.OrdinalIgnoreCase);

        // The estate minted its own execution identity and it is not the caller's request id. This
        // is asserted here rather than only in the W7F.2 suite because a real provider round trip is
        // the one path that could plausibly overwrite it.
        Assert.NotNull(response.Execution);
        Assert.False(string.IsNullOrWhiteSpace(response.Execution!.ExecutionId));
        Assert.NotEqual(response.RequestId, response.Execution.ExecutionId);
    }

    // ============================================================================================
    // Runbook item 14 - usage recorded.
    // ============================================================================================

    [Fact]
    public async Task LiveProvider_RealTurn_RecordsUsageWithTokenCounts()
    {
        RequireCredential();

        await using var estate = await LiveEstate.StartAsync();

        var response = await estate.ChatAsync(Prompt);

        Assert.Equal(AiExecutionStatus.Succeeded, response.Status);

        // REAL counts, not a stand-in reporting a constant. A fake seam can only ever prove the
        // counting code was reached; these numbers are the vendor's, which is what makes this the
        // assertion the runbook actually asks for.
        Assert.True(
            response.Usage.InputTokens > 0,
            $"a real turn must report real input tokens, got {response.Usage.InputTokens}");
        Assert.True(
            response.Usage.OutputTokens > 0,
            $"a real turn must report real output tokens, got {response.Usage.OutputTokens}");

        // The prompt is short and the answer is one word, so both counts are far below any ceiling a
        // person would expect. This is not a threshold the estate enforces; it is a sanity bound
        // that catches the failure mode where a vendor returns the wrong field and the count lands
        // in the thousands.
        Assert.True(
            response.Usage.InputTokens < 1_000,
            $"a one-word reply to a one-line prompt should not consume {response.Usage.InputTokens} input tokens");
    }

    // ============================================================================================
    // Runbook item 13 - round trip persisted across a process restart.
    // ============================================================================================

    [Fact]
    public async Task LiveProvider_RealTurn_AssistantMessageSurvivesProcessRestart()
    {
        RequireCredential();

        var hostDll = Path.Combine(AppContext.BaseDirectory, "Nexus.Intelligence.LiveSmokeHost.dll");
        Assert.True(File.Exists(hostDll), $"the live smoke host was not copied to the test output: {hostDll}");

        // Process A writes: a real turn runs, and what the caller was given is persisted, and then
        // this process EXITS. If the message lived only in process memory, nothing would survive it.
        var (sendOut, sendExit) = await RunHostAsync(hostDll, "send", Prompt);
        Assert.Equal(0, sendExit);

        var recordId = ReadField(sendOut, "ID=");
        var assistant = ReadField(sendOut, "ASSISTANT=");
        var executionId = ReadField(sendOut, "EXECUTION=");

        Assert.False(string.IsNullOrWhiteSpace(recordId), $"no record id in the host output:\n{sendOut}");
        Assert.False(string.IsNullOrWhiteSpace(executionId), $"no execution id in the host output:\n{sendOut}");
        Assert.False(string.IsNullOrWhiteSpace(assistant), $"no assistant output in the host output:\n{sendOut}");
        Assert.Contains(ExpectedToken, assistant!, StringComparison.OrdinalIgnoreCase);

        // Process B reads: a genuinely fresh OS process retrieves the same message, byte for byte.
        var (recvOut, recvExit) = await RunHostAsync(hostDll, "recv", recordId!);
        Assert.Equal(0, recvExit);
        Assert.Equal(assistant, recvOut.Trim());
    }

    /// <summary>
    /// Runs the host as a child process and captures its streams.
    /// </summary>
    /// <remarks>
    /// A non-zero exit is returned rather than thrown, so the caller reports the exit code and the
    /// captured output together. Throwing here would replace the host's own diagnostic with this
    /// method's, and the host's is the one that says what went wrong.
    /// </remarks>
    private static async Task<(string Output, int ExitCode)> RunHostAsync(string dll, params string[] args)
    {
        var startInfo = new ProcessStartInfo("dotnet", [dll, .. args])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        };

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("failed to start the dotnet host process");

        var stdout = await process.StandardOutput.ReadToEndAsync();
        var stderr = await process.StandardError.ReadToEndAsync();

        // A live vendor call plus process startup; two minutes is generous rather than tight, and it
        // is a ceiling on a hang rather than a timing assertion.
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMinutes(2));

        Assert.True(
            string.IsNullOrWhiteSpace(stderr) || process.ExitCode == 0,
            $"the live smoke host wrote to stderr:\n{stderr}\n--- stdout ---\n{stdout}");

        return (stdout, process.ExitCode);
    }

    /// <summary>Reads one <c>NAME=value</c> line from the host's output.</summary>
    private static string? ReadField(string output, string prefix) =>
        output.Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => line.StartsWith(prefix, StringComparison.Ordinal))
            ?[prefix.Length..];
}
