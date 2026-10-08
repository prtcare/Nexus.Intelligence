using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

// Extension point registered by provider packages; RoutingModelGateway resolves a
// ModelInvocation's vendor prefix ("openai:gpt-4.1") to the matching Vendor here.
//
// IUsageReportingModelGateway as well as IModelGateway: a provider adapter is the ONLY layer that can
// see whether the vendor returned a usage block, and Platform's ModelInvocationResult cannot carry
// that fact. Requiring the richer port here means every registered provider route can say "the
// provider told us nothing", so the governed path never has to guess.
public interface INamedModelGateway : IModelGateway, IUsageReportingModelGateway
{
    string Vendor { get; }
}
