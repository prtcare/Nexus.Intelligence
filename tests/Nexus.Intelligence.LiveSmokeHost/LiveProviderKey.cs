namespace Nexus.Intelligence.LiveSmokeHost;

/// <summary>
/// Where the live provider smoke path looks for a credential, and how it answers the one question
/// that may be asked of it.
/// </summary>
/// <remarks>
/// <para>
/// <b>The only question is whether a key is present. The value is never read into this type.</b>
/// <see cref="Available"/> returns a <see cref="bool"/> and is the sole way any code here learns
/// anything about the credential; no property, field, local or log line carries the value. The
/// resolution itself is performed by the estate's own
/// <c>Nexus.Platform.Core.Secrets.EnvironmentSecretResolver</c>, at the point of use, inside the
/// provider adapter — which is the boundary the estate already uses everywhere else, and which
/// means this project never handles the value even transiently.
/// </para>
/// <para>
/// <b>The reference name is the estate's approved default.</b> <c>NEXUS_OPENAI_API_KEY</c> is the
/// reference the estate already records as approved, so the live path exercises the same reference
/// a deployment would use rather than a fixture-only name. The retired Platform sample used a
/// user-secrets store at a hardcoded <c>C:\Personal</c> path; W7G.2 removed that dependency, and
/// this is the replacement: an environment reference resolved through the neutral contract.
/// </para>
/// </remarks>
public static class LiveProviderKey
{
    /// <summary>
    /// The secret REFERENCE, which is also this resolver's namespace: the environment.
    /// <c>EnvironmentSecretResolver</c> defines its namespace as process environment variables, so
    /// the reference the registry declares IS the variable name. Never a value.
    /// </summary>
    public const string ReferenceName = "NEXUS_OPENAI_API_KEY";

    /// <summary>
    /// Why the live suite cannot run, phrased as an instruction rather than an apology. Reported as
    /// the skip reason so that every skipped run says how to make it run.
    /// </summary>
    public const string SkipReason =
        "no live provider credential: set the environment variable " + ReferenceName
        + " to run the provider-specific AI Head smoke tests. These call a real vendor, cost money, "
        + "and are deliberately outside Nexus.Intelligence.slnx so they never run in CI by accident.";

    /// <summary>
    /// True when a credential is present. Reports EXISTENCE ONLY — it never returns, logs or
    /// exposes the value, and it deliberately does not validate the key, because validating a
    /// credential means sending it somewhere.
    /// </summary>
    public static bool Available() =>
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(ReferenceName));
}
