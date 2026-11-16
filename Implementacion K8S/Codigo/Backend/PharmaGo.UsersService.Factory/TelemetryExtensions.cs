using Instrumentation;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Exporter;
using OpenTelemetry.Trace;
using System.Diagnostics;

namespace PharmaGo.UsersService.Factory
{
    public static class OpenTelemetryExtensions
    {
        public static IServiceCollection AddPharmaGoOpenTelemetryMetrics(this IServiceCollection services, string serviceName = "PharmaGo.UsersService")
        {
            services.AddOpenTelemetry()
            .WithTracing(tracing => tracing
    .SetResourceBuilder(
        ResourceBuilder.CreateDefault().AddService(serviceName, serviceInstanceId: Environment.MachineName))
    .SetSampler(new ParentBasedSampler(new AlwaysOnSampler()))
    .AddAspNetCoreInstrumentation(options => options.Filter = TraceFilters.ShouldTraceRequest)
    .AddHttpClientInstrumentation()
    .AddOtlpExporter(options =>
    {
        options.Endpoint = new Uri("http://otlp-collector:4317");
        options.Protocol = OtlpExportProtocol.Grpc;
    }))
                    .WithMetrics(metricsBuilder => { metricsBuilder
                    .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(serviceName, serviceInstanceId: Environment.MachineName))
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddMeter("PharmaGo.CustomMetrics")
                    .AddOtlpExporter(options =>
                        {
                            options.Endpoint = new Uri("http://otlp-collector:4317");
                            options.Protocol = OtlpExportProtocol.Grpc;
                        });
                    });

            return services;
        }
    }
}

