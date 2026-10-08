using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Intelligence.Api.DependencyInjection;
using Nexus.Platform.Contracts.Secrets;
using Nexus.Platform.Core;
using Nexus.Platform.Core.Models;
using Nexus.Platform.Providers.OpenAI;
using Xunit;

namespace Nexus.Intelligence.Architecture.Tests;

// W7A.1 / item 3: the rotating provider credential must not be a precondition for W7B, W7C or W7D.
//
// The claim is easy to state and easy to state falsely. "The lanes are not blocked" is true for a
// trivial reason if it is only asserted in prose: nothing stops anyone writing it. What can be
// PROVED is the structural reason it is true -
//
//   (a) the contracts those lanes implement against carry no secret-VALUED member, so no lane can
//       be handed a credential by the type system even by accident; and
//   (b) the provider path COMPOSES and RESOLVES with no credential available at all, so building,
//       wiring and testing the lanes never reaches for one.
//
// The credential is consulted at exactly one moment - the outbound provider call - and nothing in
// W7B (AI Governance), W7C (Model/Provider Registry + Router) or W7D (Agents, Tools, Context)
// is on that path. That is the isolation, and it is what these two tests hold.
public sealed class W7a1CredentialIsolationTests
{
    private const string CredentialReference = "Platform:Providers:OpenAI:ApiKeyRef";

    // ---------------------------------------------------------------------------------------------
    // (a) The contract surface cannot carry a secret value.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public void Contracts_CarryNoSecretValuedMember()
    {
        var visited = 0;
        var offenders = new List<string>();

        foreach (var type in typeof(Nexus.Intelligence.Contracts.IntelligenceTurnRequest).Assembly.GetExportedTypes())
        {
            foreach (var member in PublicMemberNames(type))
            {
                visited++;

                if (IsCredentialValuedName(member) && !IsReferenceName(member))
                {
                    offenders.Add($"{type.FullName}.{member}");
                }
            }
        }

        // NON-VACUITY: the walk has to have actually walked. The Contracts assembly is the W7A
        // deliverable set and is far larger than this floor; a floor rather than an exact count so
        // that legitimate growth does not need this number edited.
        Assert.True(
            visited > 300,
            $"The member walk visited only {visited} public members. It is not reading the Contracts " +
            "assembly, so the assertion below proves nothing.");

        Assert.True(
            offenders.Count == 0,
            "A public Contracts member is named like a secret VALUE rather than a reference. W7A task 7 " +
            "requires that callers never acquire provider credentials, and the contract surface is where " +
            "that is enforced or lost. Offenders: " + string.Join(", ", offenders));
    }

    // The control arm. Without it, a name matcher that flagged nothing would make the assertion
    // above pass on any assembly, including one holding a live key property.
    [Fact]
    public void CredentialValuedNameCheck_CanFail_OnAKnownBadName()
    {
        // Positive: names that can only mean credential material.
        Assert.True(IsCredentialValuedName("ApiKey"));
        Assert.True(IsCredentialValuedName("OpenAIApiKey"));
        Assert.True(IsCredentialValuedName("ClientSecret"));
        Assert.True(IsCredentialValuedName("BearerToken"));

        // Negative: the domain vocabulary the scanner must NOT flag, each one a real member name in
        // Nexus.Intelligence.Contracts today. Asserted here so the scanner cannot be widened back
        // into noise without a failure that names the reason.
        Assert.False(IsCredentialValuedName("InputTokens"));
        Assert.False(IsCredentialValuedName("OutputTokens"));
        Assert.False(IsCredentialValuedName("MaxOutputTokens"));
        Assert.False(IsCredentialValuedName("ToToken"));
        Assert.False(IsCredentialValuedName("Secret"));
        Assert.False(IsCredentialValuedName("SecretCustody"));
        Assert.False(IsCredentialValuedName("LooksLikeSecretValue"));
        Assert.False(IsCredentialValuedName("Model"));
        Assert.False(IsCredentialValuedName("CorrelationId"));

        // The reference form is still CREDENTIAL-shaped - it names credential material - which is
        // why the rule is the pair "credential-shaped AND not a reference". "ApiKeyRef" being
        // visible to the shaped matcher is what makes the reference exclusion meaningful rather than
        // accidental: it is excluded because it SAYS it is a reference, not because the matcher
        // cannot see it.
        Assert.True(CredentialVocabulary.IsCredentialShaped("ApiKeyRef"));
        Assert.True(IsReferenceName("ApiKeyRef"));
        Assert.False(IsCredentialValuedName("ApiKeyRef"));
    }

    // ---------------------------------------------------------------------------------------------
    // (b) The provider path composes with no credential available.
    // ---------------------------------------------------------------------------------------------

    [Fact]
    public async Task ProviderPath_ComposesAndResolves_WithNoCredentialAvailable()
    {
        // No configuration value for the reference. The credential is therefore absent by
        // construction rather than merely unread.
        //
        // The composition mirrors Program.cs, minus the endpoint-scoped singletons: Platform CORE
        // first, then the provider, then the AI Head's own registrations. AddNexusIntelligence is
        // required rather than optional - OpenAIModelGateway takes IUsageMeter, and IUsageMeter is
        // an AI-Head type registered here, not by AddNexusPlatform. That is itself part of the
        // proof: the provider path composes from AI-Head registrations, so no Platform-side secret
        // wiring is on it.
        var configuration = new ConfigurationBuilder().Build();

        var serviceProvider = new ServiceCollection()
            .AddNexusPlatform(configuration)
            .AddOpenAIModelProvider(configuration)
            .AddNexusIntelligence(configuration)
            .BuildServiceProvider();

        using var _ = serviceProvider;

        // The two registrations W7C's registry/router work is built against resolve. The gateways
        // the W7B/W7D lanes are tested through resolve. None of them asks for a credential to be
        // constructed.
        Assert.NotNull(serviceProvider.GetRequiredService<INamedModelGateway>());
        Assert.NotNull(serviceProvider.GetRequiredService<IModelCatalogSource>());
        Assert.NotNull(serviceProvider.GetRequiredService<ISecretResolver>());

        // NEGATIVE CONTROL: the credential really is unavailable in this composition. If a value
        // were reachable, the run above would prove only that the lanes work on a machine that
        // happens to hold one.
        Assert.Null(await serviceProvider.GetRequiredService<ISecretResolver>().ResolveAsync(string.Empty));

        Assert.True(
            string.IsNullOrWhiteSpace(new OpenAIOptions().ApiKeyRef),
            $"The default '{nameof(OpenAIOptions.ApiKeyRef)}' is non-empty, so this composition is " +
            "reaching a reference without being told which one.");
    }

    // The single property of the provider options that sits next to a credential must be the
    // REFERENCE. Asserted as a rule over every property rather than as an exact property list, so
    // that adding a non-secret option later does not require editing this test - but adding a
    // value-bearing one fails immediately.
    [Fact]
    public void ProviderOptions_SecretAdjacentPropertiesAreReferences()
    {
        var properties = typeof(OpenAIOptions).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(p => p.Name)
            .ToArray();

        var valued = properties.Where(n => IsCredentialValuedName(n) && !IsReferenceName(n)).ToArray();

        Assert.True(
            valued.Length == 0,
            $"{nameof(OpenAIOptions)} carries a secret-VALUED property. W4L-201's blocking reason was " +
            "verbatim 'REQUIRES_HUMAN_SECRET_ROTATION - OpenAIOptions carries an ApiKey property and the " +
            $"provider is the credential consumer'. Offenders: {string.Join(", ", valued)}");

        // The reference must exist: this is the property the whole isolation rests on, and it is
        // required by name so that removing it fails here as well as at compile time in the
        // relocated secret boundary tests.
        Assert.Contains(nameof(OpenAIOptions.ApiKeyRef), properties);

        // Non-vacuity: the properties were read at all, and the rule sees a name it would flag.
        Assert.NotEmpty(properties);
        Assert.True(IsCredentialValuedName("ApiKey"));
    }

    // ---------------------------------------------------------------------------------------------
    // Shared helpers.
    // ---------------------------------------------------------------------------------------------

    private static IEnumerable<string> PublicMemberNames(Type type)
    {
        const BindingFlags Public = BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static;

        foreach (var property in type.GetProperties(Public))
        {
            yield return property.Name;
        }

        foreach (var field in type.GetFields(Public))
        {
            yield return field.Name;
        }

        foreach (var method in type.GetMethods(Public))
        {
            yield return method.Name;

            foreach (var parameter in method.GetParameters())
            {
                yield return parameter.Name ?? string.Empty;
            }

            foreach (var argument in method.GetGenericArguments())
            {
                yield return argument.Name;
            }
        }
    }

    // Delegated to the shared vocabulary so this guard and the documentation/configuration guard
    // cannot drift apart on what a credential-shaped name is.
    private static bool IsCredentialValuedName(string name) => CredentialVocabulary.IsCredentialValueName(name);

    private static bool IsReferenceName(string name) => CredentialVocabulary.IsReferenceName(name);
}
