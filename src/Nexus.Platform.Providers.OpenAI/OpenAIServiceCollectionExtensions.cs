using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Nexus.Platform.Core.Models;

namespace Nexus.Platform.Providers.OpenAI;

public static class OpenAIServiceCollectionExtensions
{
    public static IServiceCollection AddOpenAIModelProvider(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services.Configure<OpenAIOptions>(configuration.GetSection(OpenAIOptions.SectionName));

        // W7C TASK 7: the adapter's model list is bound, not compiled in. Bound from the same provider
        // section the credential reference comes from, so both halves of this provider's configuration
        // live under one path.
        services.Configure<OpenAICatalogOptions>(configuration.GetSection(OpenAICatalogOptions.SectionName));

        services.AddSingleton<INamedModelGateway, OpenAIModelGateway>();
        services.AddSingleton<IModelCatalogSource, OpenAIModelCatalogSource>();

        return services;
    }
}
