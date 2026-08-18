using Nexus.Intelligence.Contracts;

namespace Nexus.Intelligence.Core.Turns;

public interface IContextSelector
{
    ContextSelection Select(ContextBundle bundle, string query);
}
