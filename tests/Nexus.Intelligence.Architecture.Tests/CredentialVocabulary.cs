using System;
using System.Linq;

namespace Nexus.Intelligence.Architecture.Tests;

/// <summary>
/// The one name vocabulary the W7A.1 secret guards share.
/// </summary>
/// <remarks>
/// <para>
/// Shared rather than duplicated because the two guards — documentation/configuration consistency and
/// credential isolation — must agree on what a credential-shaped name IS. Two copies would drift, and
/// the drift would show up as one guard passing while the other failed on the same string, which is
/// the least useful possible outcome.
/// </para>
/// <para>
/// <b>The stems are credential-material only, and deliberately exclude the bare words "Secret",
/// "Token" and "Credential".</b> That is a measurement of this domain, not a preference. Those three
/// words name legitimate, load-bearing concepts here: "Token" matches
/// <c>InputTokens</c>/<c>OutputTokens</c>/<c>CachedInputTokens</c>/<c>MaxOutputTokens</c> and
/// <c>CapabilityId.ToToken</c> — the unit of AI accounting, which is the centre of the domain;
/// "Secret" matches <c>DataClassification.Secret</c>, the redaction detectors
/// (<c>AiRedaction.LooksLikeSecretValue</c>, <c>MinimumSecretLength</c>) and the prohibition surfaces
/// W7A.1 added (<c>SecretCustody</c>, <c>CredentialMaterial</c>). A guard that flagged those would
/// have to be suppressed on the first run, and a suppressed guard is not a guard.
/// </para>
/// <para>
/// What is left can only mean credential material. The list is not exhaustive of every credential a
/// future system might invent; it is exhaustive of the ones whose <em>names</em> are unambiguous.
/// </para>
/// </remarks>
internal static class CredentialVocabulary
{
    /// <summary>Name fragments that can only mean credential material.</summary>
    internal static readonly string[] ValueStems =
    [
        "ApiKey", "ApiSecret", "ApiToken",
        "Password", "Passphrase",
        "ClientSecret", "SigningSecret",
        "PrivateKey",
        "ConnectionString",
        "BearerToken", "AccessToken", "RefreshToken", "AuthToken", "IdToken", "PersonalAccessToken",
    ];

    /// <summary>
    /// True when the name is shaped like credential material. Says nothing about whether it is a
    /// reference — <c>ApiKeyRef</c> is credential-shaped, which is why callers pair this with
    /// <see cref="IsReferenceName"/>.
    /// </summary>
    internal static bool IsCredentialShaped(string name)
        => ValueStems.Any(stem => name.Contains(stem, StringComparison.OrdinalIgnoreCase));

    /// <summary>True when the name declares a reference rather than a value.</summary>
    internal static bool IsReferenceName(string name)
        => name.EndsWith("Ref", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// True when the name is a defect: shaped like credential material and not declaring itself a
    /// reference.
    /// </summary>
    internal static bool IsCredentialValueName(string name)
        => IsCredentialShaped(name) && !IsReferenceName(name);
}
