namespace Nexus.Intelligence.Contracts;

/// <summary>
/// How sensitive the data carried by an AI request is. Governs what may be sent, to where, and for
/// how long it may be retained.
/// </summary>
/// <remarks>
/// <para>
/// The set is deliberately the eight classes the W7A directive names. It <b>supersedes</b> the
/// four-value sketch in <c>V3_M1B_AI_CAPABILITY_CONTRACT.md</c> §4 (<c>Public, Internal,
/// Confidential, Restricted</c>): <c>Restricted</c> conflated personal, financial, code and
/// customer data into one bucket, and the whole point of the classification is that those four
/// travel under different rules.
/// </para>
/// <para>
/// The values are ordered by ascending sensitivity. <see cref="DataClassificationExtensions"/> relies
/// on that order; do not renumber, and append new members at the sensitive end so that
/// "at least as sensitive as" comparisons stay correct.
/// </para>
/// </remarks>
public enum DataClassification
{
    /// <summary>Already published or publishable. No exposure constraint.</summary>
    Public = 0,

    /// <summary>Ordinary internal material. Not for external publication, not personal.</summary>
    Internal = 1,

    /// <summary>Internal material whose disclosure would cause harm. Commercial-in-confidence.</summary>
    Confidential = 2,

    /// <summary>Personally identifiable information about a natural person.</summary>
    Pii = 3,

    /// <summary>Financial records, ledgers, payment data, forecasts that are not yet public.</summary>
    Financial = 4,

    /// <summary>Source code and repository content that is not public.</summary>
    SourceCode = 5,

    /// <summary>Data belonging to a customer or tenant, held on their behalf.</summary>
    CustomerData = 6,

    /// <summary>Credentials, keys, tokens and material whose disclosure is itself the incident.</summary>
    Secret = 7,
}
