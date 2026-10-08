using System.Xml.Linq;
using Nexus.Intelligence.LiveSmokeHost;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

/// <summary>
/// Keeps the AI Head's provider-specific smoke projects from rotting the way their predecessor did.
/// </summary>
/// <remarks>
/// <para>
/// <b>The failure being prevented is specific and it happened.</b> The Platform suite this lane
/// re-homed held a <c>ProjectReference</c> to a project that no longer existed, and because nothing in
/// any solution built it, no build went red. It was found by reading, months later, not by running.
/// Two structural facts made that possible: the reference was unresolvable, and nothing ever compiled
/// the file that held it.
/// </para>
/// <para>
/// <b>The AI Head's live test project is deliberately outside <c>Nexus.Intelligence.slnx</c></b> —
/// every run calls a paid vendor, and putting that in every lane's default <c>dotnet test</c> would be
/// a spending decision nobody authorised. So it cannot supply its own build signal, and this file
/// supplies it instead: the assertions below run on <b>every</b> default test run, in the solution,
/// and cost nothing.
/// </para>
/// <para>
/// <b>The host is compiled by the solution, so it is checked as a real assembly.</b> The architecture
/// test project references <c>Nexus.Intelligence.LiveSmokeHost</c>; that reference means the fixture
/// is built on every test run, and the reflection assertions below are then statements about compiled
/// code rather than about text. Building is not running: nothing here constructs the estate, resolves
/// a credential, or contacts a vendor.
/// </para>
/// <para>
/// <b>What the file-text checks are, said plainly.</b> The live TEST project is not built, so its
/// assertions cannot be reflected over; they are checked by reading its source for the declarations it
/// must keep. That is a lint and not a proof, and it is labelled as one here so no reader mistakes it
/// for compilation. What it does catch is the realistic rot — a test renamed away, a call site
/// rewritten, the whole file emptied — because each of those changes the text.
/// </para>
/// </remarks>
public sealed class LiveSmokeProjectIntegrityTests
{
    private const string HostProjectRelative = @"tests\Nexus.Intelligence.LiveSmokeHost\Nexus.Intelligence.LiveSmokeHost.csproj";
    private const string TestsProjectRelative = @"tests\Nexus.Intelligence.LiveSmokeTests\Nexus.Intelligence.LiveSmokeTests.csproj";
    private const string TestsSourceRelative = @"tests\Nexus.Intelligence.LiveSmokeTests\LiveProviderSmokeTests.cs";

    /// <summary>
    /// The three provider-specific smoke checks, by the names the migration runbook's items fix.
    /// </summary>
    /// <remarks>
    /// Named individually rather than counted, because a suite that has three tests of which two are
    /// the wrong three is exactly the state this estate's audits keep finding. The names are the
    /// runbook's items 12, 13 and 14 in the order that document lists them.
    /// </remarks>
    private static readonly string[] RequiredSmokeTests =
    [
        "LiveProvider_RealTurn_ReturnsModelResponse",
        "LiveProvider_RealTurn_AssistantMessageSurvivesProcessRestart",
        "LiveProvider_RealTurn_RecordsUsageWithTokenCounts",
    ];

    /// <summary>The public surface the live tests call, and which must therefore still exist.</summary>
    /// <remarks>
    /// Asserted through the compiled host rather than through text: if the fixture's shape drifts, the
    /// live suite stops compiling, and nobody would find out until someone next spent money running
    /// it. This is the cheapest possible version of "the paid suite would still build".
    /// </remarks>
    [Fact]
    public void LiveSmokeHost_StillExposesTheSurfaceTheLiveTestsCall()
    {
        var host = typeof(LiveEstate);

        Assert.NotNull(host.GetMethod(nameof(LiveEstate.StartAsync), Type.EmptyTypes));
        Assert.NotNull(host.GetMethod(nameof(LiveEstate.ChatAsync)));
        Assert.NotNull(host.GetMethod(nameof(LiveEstate.BuildConfiguration), Type.EmptyTypes));

        // The credential boundary is a type with two members and no value-bearing one. Both are
        // asserted because both are load-bearing: the live suite branches on Available, and a runner
        // reads SkipReason to find out what to set.
        var key = typeof(LiveProviderKey);
        Assert.NotNull(key.GetMethod(nameof(LiveProviderKey.Available), Type.EmptyTypes));
        Assert.NotNull(key.GetField(nameof(LiveProviderKey.SkipReason)));
        Assert.NotNull(key.GetField(nameof(LiveProviderKey.ReferenceName)));

        // The restart check needs a store and a record; the record's factory is what refuses to
        // persist a non-success response, so it is part of the surface and not an implementation
        // detail of the host.
        Assert.NotNull(typeof(LiveChatStore).GetMethod(nameof(LiveChatStore.Save)));
        Assert.NotNull(typeof(LiveChatStore).GetMethod(nameof(LiveChatStore.Load)));
        Assert.NotNull(typeof(LiveTurnRecord).GetMethod(nameof(LiveTurnRecord.From)));
    }

    /// <summary>
    /// Every reference the two live projects declare resolves to something that exists.
    /// </summary>
    /// <remarks>
    /// This is the predecessor's exact failure, tested for. A <c>ProjectReference</c> to a deleted
    /// project is invisible at rest — no solution builds it, so no build fails — and it stays
    /// invisible until someone tries to run the suite and gets a restore error instead of a test
    /// result. Reading the file and resolving each path turns that into a failure on every run.
    /// </remarks>
    [Theory]
    [InlineData(HostProjectRelative)]
    [InlineData(TestsProjectRelative)]
    public void LiveSmokeProjects_EveryDeclaredProjectReferenceResolvesOnDisk(string relativeProject)
    {
        var projectPath = Path.Combine(RepositoryRoot(), relativeProject);

        Assert.True(File.Exists(projectPath), $"the live smoke project is missing: {relativeProject}");

        var directory = Path.GetDirectoryName(projectPath)!;
        var references = ProjectReferenceIncludes(projectPath).ToArray();

        Assert.NotEmpty(references);

        foreach (var include in references)
        {
            // MSBuild project references are written with Windows separators regardless of host, so
            // both separators are normalised before the path is resolved.
            var resolved = Path.GetFullPath(Path.Combine(directory, include.Replace('\\', Path.DirectorySeparatorChar)));

            Assert.True(
                File.Exists(resolved),
                $"{relativeProject} references '{include}', which does not exist at {resolved}. This is "
                + "the failure that destroyed the retired Platform smoke suite: the reference was "
                + "dangling and nothing in any solution built the file holding it, so no build went red.");
        }
    }

    /// <summary>
    /// The live test project is outside the solution, and that is a decision rather than an oversight.
    /// </summary>
    /// <remarks>
    /// Two failures are prevented by pinning it. If someone adds it to the solution, every lane's
    /// default test run starts making paid vendor calls — a cost decision this lane is not authorised
    /// to make, and one that would be made silently by a one-line edit. If someone instead leaves it
    /// out believing it is merely forgotten, this test is where the reason is written down.
    /// </remarks>
    [Fact]
    public void LiveSmokeTests_AreDeliberatelyOutsideTheSolution()
    {
        var solution = Path.Combine(RepositoryRoot(), "Nexus.Intelligence.slnx");

        Assert.True(File.Exists(solution), $"the estate's solution file is missing: {solution}");

        var text = File.ReadAllText(solution);

        Assert.DoesNotContain("LiveSmokeTests", text, StringComparison.Ordinal);
        Assert.DoesNotContain("LiveSmokeHost", text, StringComparison.Ordinal);
    }

    /// <summary>The three re-homed runbook checks are still declared where the runbook puts them.</summary>
    [Fact]
    public void LiveSmokeTests_StillDeclareTheThreeRehomedRunbookChecks()
    {
        var source = Path.Combine(RepositoryRoot(), TestsSourceRelative);

        Assert.True(File.Exists(source), $"the re-homed smoke suite is missing: {TestsSourceRelative}");

        var text = File.ReadAllText(source);

        foreach (var name in RequiredSmokeTests)
        {
            Assert.True(
                text.Contains($"Task {name}(", StringComparison.Ordinal),
                $"{TestsSourceRelative} no longer declares '{name}'. The three checks are migration "
                + "runbook items 12, 13 and 14; losing one silently would leave the runbook claiming a "
                + "coverage the estate does not have.");
        }
    }

    /// <summary>
    /// The live suite's own secrets never leave the neutral ISecretResolver contract.
    /// </summary>
    /// <remarks>
    /// The fixture resolves its credential through the estate's neutral <c>ISecretResolver</c>, bound
    /// to the environment-backed implementation. A provider-specific credential type appearing in the
    /// fixture would be the same ownership mistake Gate 9's Platform rule exists to catch, in the
    /// repository that is supposed to be allowed to hold providers — so it is checked here too, and
    /// the check is that no live file declares a type whose name reads as a vendor's own key type.
    /// </remarks>
    [Fact]
    public void LiveSmokeFixture_NamesNoVendorCredentialType()
    {
        var directory = Path.Combine(RepositoryRoot(), @"tests\Nexus.Intelligence.LiveSmokeHost");

        var sources = Directory
            .EnumerateFiles(directory, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            .ToArray();

        Assert.NotEmpty(sources);

        foreach (var path in sources)
        {
            var text = File.ReadAllText(path);

            Assert.DoesNotContain("OpenAIClient", text, StringComparison.Ordinal);
            Assert.DoesNotContain("ApiKey =", text, StringComparison.Ordinal);
            Assert.DoesNotContain("ApiKey=", text, StringComparison.Ordinal);

            // The provider is reached through the estate's own registration extension, never by
            // constructing a gateway by hand with a key in hand.
            Assert.DoesNotContain("new OpenAIModelGateway(", text, StringComparison.Ordinal);
        }
    }

    /// <summary>The reference and the reason, in the one file that has to carry them.</summary>
    /// <remarks>
    /// The live test project is outside the solution, so its <c>.csproj</c> comment is the only place
    /// a reader will look for why. Asserting the reason is stated keeps the decision from decaying
    /// into an unexplained absence, which is how the predecessor's arrangement was read.
    /// </remarks>
    [Fact]
    public void LiveSmokeTests_StateWhyTheyAreOutsideTheSolution()
    {
        var text = File.ReadAllText(Path.Combine(RepositoryRoot(), TestsProjectRelative));

        Assert.Contains("NOT IN Nexus.Intelligence.slnx", text, StringComparison.Ordinal);
        Assert.Contains("SPEND THE OWNER'S MONEY", text, StringComparison.Ordinal);
        Assert.Contains("LiveSmokeProjectIntegrityTests", text, StringComparison.Ordinal);
    }

    /// <summary>Walks up from the test binaries to the repository root, identified by its solution.</summary>
    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "Nexus.Intelligence.slnx")))
        {
            directory = directory.Parent;
        }

        Assert.NotNull(directory);

        return directory!.FullName;
    }

    /// <summary>Every <c>&lt;ProjectReference Include="..." /&gt;</c> a project file declares.</summary>
    private static IEnumerable<string> ProjectReferenceIncludes(string projectPath) =>
        XDocument.Load(projectPath)
            .Descendants()
            .Where(element => element.Name.LocalName == "ProjectReference")
            .Select(element => element.Attribute("Include")?.Value)
            .Where(include => !string.IsNullOrWhiteSpace(include))
            .Select(include => include!);
}
