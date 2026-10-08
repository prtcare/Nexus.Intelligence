using Nexus.Platform.Contracts.Models;

namespace Nexus.Platform.Core.Models;

// Extension point registered by provider packages; RoutingModelGateway resolves a
// ModelInvocation's vendor prefix ("openai:gpt-4.1") to the matching Vendor here.
public interface INamedModelGateway : IModelGateway
{
    string Vendor { get; }
}
