using System.Globalization;
using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Operations;

/// <summary>
/// The price catalogue, read from the model registry's own pricing metadata.
/// </summary>
/// <remarks>
/// <para>
/// <b>It does not own a price table, and that is the directive's requirement rather than a
/// preference.</b> The registry already declares each model's input and output rates, the currency
/// they are in and where they were transcribed from. A second table would be a second answer to
/// "what does this cost", and the two would disagree the first time someone corrected one of them —
/// with no mechanism anywhere that would notice.
/// </para>
/// <para>
/// <b>Tier support and tier rates are different facts, and only the first is modelled here.</b> A
/// model declares which processing tiers it may be run under
/// (<see cref="AiModelRegistration.ProcessingTiers"/>); the estate records one rate pair per model.
/// Where an estate has genuinely different rates per tier, the registration gains rates per tier and
/// this catalogue reads them — W7E does not invent per-tier numbers, because a made-up discount is
/// indistinguishable from a real one once it is in a ledger.
/// </para>
/// <para>
/// <b>The lookup never guesses between candidates.</b> A model identifier names one model, and that
/// model names one provider, so there is no tie to break and no ordering question. A lookup that
/// found two quotes would report <see cref="AiPricingLookupState.Ambiguous"/> rather than pick one,
/// because picking one is how a wrong rate becomes a budget decision nobody can reproduce.
/// </para>
/// </remarks>
public sealed class ConfiguredAiPriceCatalogue : IAiPriceCatalogue
{
    private readonly IAiModelRegistry _models;

    /// <summary>Builds a catalogue over the model registry.</summary>
    public ConfiguredAiPriceCatalogue(IAiModelRegistry models)
    {
        ArgumentNullException.ThrowIfNull(models);
        _models = models;
    }

    /// <inheritdoc />
    public AiPriceLookup Lookup(string modelId, string providerId, AiProcessingTier tier)
    {
        if (string.IsNullOrWhiteSpace(modelId) || string.IsNullOrWhiteSpace(providerId))
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                "No model or provider identifier was supplied, so no price can be resolved.");
        }

        if (!_models.TryGetModel(modelId, out var model) || model is null)
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                $"No model is registered under '{modelId}', so it has no price.");
        }

        // The model's own provider is authoritative. A caller naming a different provider is asking
        // about a route that does not exist, and answering with this model's price would price a
        // route nobody can take.
        if (!string.Equals(model.ProviderId, providerId, StringComparison.Ordinal))
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                $"Model '{modelId}' is served by provider '{model.ProviderId}', not by '{providerId}', so "
                + "no price exists for that pairing.");
        }

        if (!model.SupportsTier(tier))
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                $"Model '{modelId}' does not declare support for processing tier '{tier}'. The declared "
                + "tiers are the only source for that question; support is never inferred from a model or "
                + "provider name.");
        }

        if (model.InputCostPer1kTokens is not { } inputRate || model.OutputCostPer1kTokens is not { } outputRate)
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                $"Model '{modelId}' states no rate for both input and output tokens. One rate unstated makes "
                + "the whole estimate unknown rather than half-known, because pricing one direction while "
                + "guessing the other produces a number that is wrong by an unknown amount.");
        }

        if (string.IsNullOrWhiteSpace(model.CostCurrency))
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.NotFound,
                $"Model '{modelId}' states rates without a currency. A figure with no unit cannot be compared "
                + "against a ceiling.");
        }

        if (model.PriceStatus is AiPricingStatus.Expired)
        {
            return AiPriceLookup.Miss(
                AiPricingLookupState.Expired,
                $"The rates recorded for model '{modelId}' are marked expired, so they are recorded but not "
                + "used. Pricing from a rate the estate knows is out of date would produce a budget decision "
                + "resting on a number nobody stands behind.");
        }

        return AiPriceLookup.Hit(new AiPriceQuote
        {
            QuoteId = QuoteIdFor(providerId, modelId, tier),
            ModelId = modelId,
            ProviderId = providerId,
            Tier = tier,
            InputCostPer1kTokens = inputRate,
            OutputCostPer1kTokens = outputRate,
            Currency = model.CostCurrency.Trim(),
            Status = model.PriceStatus,
            EffectiveFrom = model.PriceEffectiveFrom,
            EffectiveTo = model.PriceEffectiveTo,
            Source = model.CostMetadataReference,
        });
    }

    /// <summary>
    /// The stable identifier for one model's price at one tier.
    /// </summary>
    /// <remarks>
    /// Derived from identity and nothing else — no timestamp, no sequence, no hash of the rates. A
    /// quote identifier that changed when a rate changed would make two cost ledger entries for the
    /// same rate look like two different rates, which is the opposite of what the field is for: it
    /// exists so a cost figure can say which price produced it, and a correction to that price should
    /// leave the identifier pointing at the same subject.
    /// </remarks>
    public static string QuoteIdFor(string providerId, string modelId, AiProcessingTier tier)
        => string.Create(
            CultureInfo.InvariantCulture,
            $"price:{providerId}:{modelId}:{tier.ToString().ToLowerInvariant()}");
}
