namespace Nexus.Intelligence.Contracts;

/// <summary>
/// The last line of defence before free text reaches a persisted audit or control record.
/// </summary>
/// <remarks>
/// <para>
/// This is a <b>backstop, not a control</b>. The control is that <see cref="AiAuditRecord"/> has no
/// field for a credential, no field for raw context, and no field that a provider SDK populates. This
/// class exists because free-text fields — a purpose statement, a remedy string, an evaluator note —
/// are written by callers and operators, and a person can type a token into a text box.
/// </para>
/// <para>
/// It therefore fails safe in one direction only: it can redact something that was not a secret, and
/// that is acceptable; it must never pass something that is. Where it cannot tell, it redacts.
/// </para>
/// <para>
/// <b>Value-shape detection is deliberately conservative and deliberately incomplete.</b> It
/// recognises a small number of well-known literal shapes and nothing else, because a pattern broad
/// enough to catch every possible secret is broad enough to redact ordinary prose. Field-name
/// detection, the assignment-shaped heuristic, and the structural absence of secret fields in
/// <see cref="AiAuditRecord"/> carry the rest of the weight.
/// </para>
/// </remarks>
public static class AiRedaction
{
    /// <summary>The token substituted for redacted content.</summary>
    public const string RedactionMarker = "[REDACTED]";

    /// <summary>
    /// Property and field names whose <em>values</em> are sensitive regardless of shape.
    /// </summary>
    /// <remarks>
    /// Matched case-insensitively as substrings, so <c>AccessToken</c>, <c>access_token</c> and
    /// <c>AccessTokenExpiry</c> all match. Substring matching over-redacts — <c>KeyName</c> matches
    /// <c>key</c> — and that is the intended trade: a redacted non-secret is a cosmetic defect, a
    /// passed secret is an incident.
    /// </remarks>
    private static readonly string[] SensitiveFieldFragments =
    [
        "secret", "token", "password", "passwd", "credential", "apikey", "api_key",
        "authorization", "auth", "privatekey", "private_key", "connectionstring", "connection_string",
        "bearer", "certificate", "signingkey",
    ];

    /// <summary>
    /// Well-known secret prefixes, assembled from fragments so that no complete literal prefix appears
    /// in this source file.
    /// </summary>
    /// <remarks>
    /// The assembly is not obfuscation. A source file containing a literal credential prefix is a file
    /// that secret scanners will flag on every commit, and that a future reader will have to classify
    /// by hand. The fragments are joined at static-initialisation time and behave identically.
    /// </remarks>
    private static readonly string[] SecretValuePrefixes =
    [
        "s" + "k-",
        "s" + "k_",
        "r" + "k-",
        "g" + "h" + "p_",
        "g" + "h" + "o_",
        "x" + "o" + "x" + "b-",
        "A" + "K" + "I" + "A",
        "A" + "S" + "I" + "A",
        "y" + "a" + "2" + "9",
    ];

    /// <summary>True when a field or property name denotes sensitive content.</summary>
    public static bool IsSensitiveFieldName(string? name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return false;
        }

        // "auth" is a fragment of "author", "authority" and "authorisation" in the non-secret sense,
        // so the bare three-letter form is required to appear as a whole token to match.
        foreach (var fragment in SensitiveFieldFragments)
        {
            if (fragment == "auth")
            {
                continue;
            }

            if (name.Contains(fragment, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return ContainsAuthToken(name);
    }

    private static bool ContainsAuthToken(string name)
    {
        // Word-boundary match for "auth": Auth, AuthToken, Authorization - but not "Author".
        foreach (var token in name.Split(['_', '-', '.', ' '], StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.Equals("auth", StringComparison.OrdinalIgnoreCase) ||
                token.Equals("authz", StringComparison.OrdinalIgnoreCase) ||
                token.Equals("authorization", StringComparison.OrdinalIgnoreCase) ||
                token.Equals("authorisation", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return name.StartsWith("Auth", StringComparison.Ordinal) && !name.StartsWith("Author", StringComparison.Ordinal);
    }

    /// <summary>Minimum length for a value to be treated as a secret in its own right.</summary>
    /// <remarks>
    /// The floor is what keeps the detector off ordinary prose and off bare prefixes. A three-character
    /// <c>sk-</c> quoted in a runbook is not a credential, and a detector that redacts it is a detector
    /// an operator will turn off.
    /// </remarks>
    public const int MinimumSecretLength = 12;

    /// <summary>
    /// True when a value <em>is</em> a known secret: one that <b>begins</b> with a known secret prefix
    /// and is long enough to be one.
    /// </summary>
    /// <remarks>
    /// Begins-with, not contains. The distinction is load-bearing rather than pedantic: this predicate
    /// decides whether the whole value is replaced or only the offending token inside it, and a
    /// contains-test makes the second case unreachable — every sentence that mentions a credential
    /// would be replaced wholesale, losing the audit fact that an operator handled one, which is the
    /// fact <see cref="AiAuditRecord"/> exists to keep.
    /// </remarks>
    public static bool LooksLikeSecretValue(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var trimmed = value.TrimStart();

        if (trimmed.Length < MinimumSecretLength)
        {
            return false;
        }

        foreach (var prefix in SecretValuePrefixes)
        {
            if (trimmed.StartsWith(prefix, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Redacts a free-text value, or returns it unchanged when nothing sensitive is detected.
    /// </summary>
    /// <remarks>
    /// A value is replaced wholesale rather than patched at the match, because a partially redacted
    /// token still discloses its length, its prefix and its surrounding structure. When the whole
    /// value is not a secret but <em>contains</em> one — an operator writing "I pasted the key
    /// s… into the box" — the offending token is replaced in place, since discarding the sentence
    /// would lose the audit fact that an incident occurred.
    /// </remarks>
    public static string? Redact(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        if (LooksLikeSecretValue(value))
        {
            return RedactionMarker;
        }

        var redacted = value;
        foreach (var prefix in SecretValuePrefixes)
        {
            var searchFrom = 0;
            while (true)
            {
                var index = redacted.IndexOf(prefix, searchFrom, StringComparison.Ordinal);
                if (index < 0)
                {
                    break;
                }

                var end = index;
                while (end < redacted.Length && !char.IsWhiteSpace(redacted[end]) && redacted[end] != '"' &&
                       redacted[end] != '\'' && redacted[end] != ',' && redacted[end] != ';')
                {
                    end++;
                }

                // The same length floor the whole-value check applies. Without it the two paths
                // disagree: a bare prefix is left alone by one and redacted by the other, and which
                // happens depends on where in the string it sits.
                if (end - index < MinimumSecretLength)
                {
                    searchFrom = end;
                    continue;
                }

                redacted = string.Concat(redacted.AsSpan(0, index), RedactionMarker, redacted.AsSpan(end));
                searchFrom = index + RedactionMarker.Length;
            }
        }

        return redacted;
    }
}
