using Microsoft.AspNetCore.Http;

namespace Instrumentation;

public static class TraceFilters
{
    /// <summary>
    /// Filter for AddAspNetCoreInstrumentation: skips kubelet probes, which are /health requests
    /// that do not continue an existing trace. A /health call made inside a traced request
    /// (users -> pharmacy ping) carries traceparent and keeps its span.
    /// </summary>
    public static bool ShouldTraceRequest(HttpContext context) =>
        !(context.Request.Path.StartsWithSegments("/health")
          && !context.Request.Headers.ContainsKey("traceparent"));
}
