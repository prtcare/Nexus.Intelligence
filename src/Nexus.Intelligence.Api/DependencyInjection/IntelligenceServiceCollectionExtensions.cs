using Nexus.Intelligence.Agents;
using Nexus.Intelligence.Agents.Abstractions;
using Nexus.Intelligence.Agents.BuiltIn;
using Nexus.Intelligence.Context.Prompting;
using Nexus.Intelligence.Context.Ranking;
using Nexus.Intelligence.Core.Execution;
using Nexus.Intelligence.Core.Planning;
using Nexus.Intelligence.Core.Turns;
using Nexus.Intelligence.Memory;

namespace Nexus.Intelligence.Api.DependencyInjection;

public static class IntelligenceServiceCollectionExtensions
{
    public static IServiceCollection AddNexusIntelligence(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddSingleton<IContextRanker, KeywordContextRanker>();
        services.AddSingleton<IPromptAssembler, PromptAssembler>();

        services.AddSingleton<IMemoryStore, InMemoryMemoryStore>();

        services.AddSingleton<IAgent, DeveloperAgent>();
        services.AddSingleton<IAgentRegistry, AgentRegistry>();
        services.AddSingleton<IAgentRuntime, AgentRuntime>();
        services.AddSingleton<IAgentDispatcher, AgentDispatcher>();

        services.AddSingleton<IIntentClassifier, IntentClassifier>();
        services.AddSingleton<IPolicyGate, PolicyGate>();
        services.AddSingleton<IContextSelector, ContextSelector>();
        services.AddSingleton<IAgentSelector, AgentSelector>();
        services.AddSingleton<IModelSelector, ModelSelector>();
        services.AddSingleton<IPromptStep, PromptStep>();
        services.AddSingleton<IModelStep, ModelStep>();
        services.AddSingleton<IToolLoop, ToolLoop>();
        services.AddSingleton<IResponseComposer, ResponseComposer>();
        services.AddSingleton<ITurnTraceStore, InMemoryTurnTraceStore>();
        services.AddSingleton<ITurnPipeline, TurnPipeline>();

        services.AddSingleton<IPlanner, Planner>();
        services.AddSingleton<IExecutionEngine, ExecutionEngine>();

        return services;
    }
}
