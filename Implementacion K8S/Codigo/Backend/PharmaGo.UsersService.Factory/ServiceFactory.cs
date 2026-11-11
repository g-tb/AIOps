using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using PharmaGo.UsersService.BusinessLogic;
using PharmaGo.DataAccess;
using PharmaGo.DataAccess.Repositories;
using PharmaGo.Domain.Entities;
using PharmaGo.UsersService.IBusinessLogic;
using PharmaGo.IDataAccess;
using Microsoft.Extensions.Hosting;
using InstrumentationInterface;
using Instrumentation;
using Microsoft.Extensions.Logging;
using Polly;
using Polly.CircuitBreaker;
using Polly.Extensions.Http;
using Polly.Timeout;


namespace PharmaGo.UsersService.Factory
{
    public static class ServiceFactory
    {

        public static void RegisterBusinessLogicServices(this IServiceCollection serviceCollection, IConfiguration configuration)
        {
            serviceCollection.AddScoped<ILoginManager, LoginManager>();
            serviceCollection.AddScoped<IUsersManager, UsersManager>();
            serviceCollection.AddScoped<IInvitationManager, InvitationManager>();
            serviceCollection.AddScoped<IRoleManager, RoleManager>();
            
            // Stateful: one circuit per UsersService replica, not one per request.
            serviceCollection.AddSingleton<AsyncCircuitBreakerPolicy<HttpResponseMessage>>(services =>
                GetCircuitBreakerPolicy(services, configuration));

            serviceCollection.AddHttpClient<PharmaGo.UsersService.HttpClients.PharmacyServiceClient>(client =>
            {
                var serviceUrl = configuration["ServiceUrls:PharmacyService"] ?? "http://127.0.0.1:5002";
                client.BaseAddress = new Uri(serviceUrl);
                client.Timeout = TimeSpan.FromSeconds(30);
            })
            .AddPolicyHandler((services, request) =>
                (request.Method == HttpMethod.Get || request.Method == HttpMethod.Head)
                    && request.Content == null
                    ? GetRetryPolicy(services, configuration)
                    : Policy.NoOpAsync<HttpResponseMessage>())
            .AddPolicyHandler((services, _) => services
                .GetRequiredService<AsyncCircuitBreakerPolicy<HttpResponseMessage>>())
            .AddPolicyHandler(Policy.TimeoutAsync<HttpResponseMessage>(
                TimeSpan.FromSeconds(configuration.GetValue("PharmacyResilience:AttemptTimeoutSeconds", 2)),
                TimeoutStrategy.Optimistic));
        }

        private static IAsyncPolicy<HttpResponseMessage> GetRetryPolicy(
            IServiceProvider services, IConfiguration configuration)
        {
            var logger = services.GetRequiredService<ILoggerFactory>()
                .CreateLogger("PharmaGo.Resilience.PharmacyServiceClient");
            var retryCount = configuration.GetValue("PharmacyResilience:RetryCount", 3);
            var baseDelay = configuration.GetValue("PharmacyResilience:BaseDelayMilliseconds", 2000);
            return HttpPolicyExtensions.HandleTransientHttpError()
                .Or<TimeoutRejectedException>()
                .WaitAndRetryAsync(retryCount,
                    // Full jitter: 0-2s, 0-4s, 0-8s with the default settings.
                    attempt => TimeSpan.FromMilliseconds(Random.Shared.NextDouble()
                        * baseDelay * Math.Pow(2, attempt - 1)),
                    onRetry: (outcome, delay, attempt, _) =>
                    {
                        logger.LogWarning(
                            "Retry scheduled. Dependency=PharmacyService Attempt={Attempt} " +
                            "DelayMs={DelayMs} LastError={LastError}",
                            attempt, delay.TotalMilliseconds,
                            outcome.Exception?.GetType().Name ?? outcome.Result?.StatusCode.ToString());
                        outcome.Result?.Dispose();
                    });
        }

        private static AsyncCircuitBreakerPolicy<HttpResponseMessage> GetCircuitBreakerPolicy(
            IServiceProvider services, IConfiguration configuration)
        {
            var logger = services.GetRequiredService<ILoggerFactory>()
                .CreateLogger("PharmaGo.Resilience.PharmacyServiceClient");
            return HttpPolicyExtensions.HandleTransientHttpError()
                .Or<TimeoutRejectedException>()
                .CircuitBreakerAsync(
                    configuration.GetValue("PharmacyResilience:FailureThreshold", 5),
                    TimeSpan.FromSeconds(configuration.GetValue("PharmacyResilience:BreakSeconds", 30)),
                    onBreak: (outcome, delay) => logger.LogWarning(
                        "Circuit opened. Dependency=PharmacyService BreakSeconds={BreakSeconds} LastError={LastError}",
                        delay.TotalSeconds, outcome.Exception?.GetType().Name ?? outcome.Result?.StatusCode.ToString()),
                    onReset: () => logger.LogInformation("Circuit closed. Dependency=PharmacyService"),
                    onHalfOpen: () => logger.LogInformation("Circuit half-open. Dependency=PharmacyService"));
        }

        public static void RegisterDataAccessServices(this IServiceCollection serviceCollection, IConfiguration configuration)
        {
            serviceCollection.AddScoped<IRepository<User>, UsersRepository>();
            serviceCollection.AddScoped<IRepository<Session>, SessionRepository>();
            serviceCollection.AddScoped<IRepository<Invitation>, InvitationRepository>();
            serviceCollection.AddScoped<IRepository<Role>, RoleRepository>();
            serviceCollection.AddScoped<IRepository<Pharmacy>, PharmacyRepository>();

            serviceCollection.AddDbContext<DbContext, PharmacyGoDbContext>(options =>
            {
                options.UseSqlServer(
                    configuration.GetConnectionString("DefaultConnection"),
                    sqlOptions => { sqlOptions.MigrationsAssembly("PharmaGo.DataAccess"); });
                options.ConfigureWarnings(w =>
                {
                    w.Ignore(RelationalEventId.CommandExecuted);
                    w.Ignore(RelationalEventId.CommandError);
                });
            });
            serviceCollection.AddSingleton<ICustomMetrics, CustomMetrics>();
            serviceCollection.AddSingleton<IStructuredLogger, StructuredLogger>();
        }

        public static IHost MigrateDatabase(this IHost host)
        {
            using (var scope = host.Services.CreateScope())
            {
                var dbContext = scope.ServiceProvider.GetRequiredService<DbContext>();
                dbContext.Database.Migrate();
            }

            return host;
        }

    }
}

