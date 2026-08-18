using Nexus.Platform.Contracts.Tools;

namespace Nexus.Intelligence.Api.Tooling;

// TODO(V2): replace with Nexus.Platform.Tools' governed tool gateway once implemented
// (see Nexus.Platform.Tools/ToolProvider.cs). Until then no tool call can succeed.
public sealed class EmptyToolGateway : IToolGateway
{
    public Task<ToolResult> InvokeAsync(ToolInvocation invocation, CancellationToken ct = default) =>
        Task.FromResult(new ToolResult
        {
            Success = false,
            Error = $"No tool gateway is configured; tool '{invocation.ToolId}' cannot be invoked."
        });
}
