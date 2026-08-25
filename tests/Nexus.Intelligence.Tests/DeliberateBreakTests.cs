using Xunit;

namespace Nexus.Intelligence.Tests;

/// <summary>
/// Deliberate break added temporarily to prove the CI pipeline turns red on a
/// test failure (M-08-1.2 acceptance #4). Reverted immediately after the red run.
/// </summary>
public sealed class DeliberateBreakTests
{
    [Fact]
    public void Deliberately_Broken_To_Prove_CI_Gates()
    {
        Assert.True(false, "Deliberate break: CI should report this as failed.");
    }
}
