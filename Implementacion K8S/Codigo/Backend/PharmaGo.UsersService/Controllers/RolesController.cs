using Microsoft.AspNetCore.Mvc;
using PharmaGo.UsersService.IBusinessLogic;
using PharmaGo.UsersService.Models.Out;
using PharmaGo.UsersService.HttpClients;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace PharmaGo.UsersService.Controllers
{
    [Route("api/[controller]")]
    [ApiController]
    public class RolesController : ControllerBase
    {
        private readonly IRoleManager _roleManager;
        private readonly PharmacyServiceClient _pharmacyServiceClient;
        private readonly AsyncCircuitBreakerPolicy<HttpResponseMessage> _circuit;

        public RolesController(IRoleManager manager, PharmacyServiceClient pharmacyServiceClient,
            AsyncCircuitBreakerPolicy<HttpResponseMessage> circuit)
        {
            _roleManager = manager;
            _pharmacyServiceClient = pharmacyServiceClient;
            _circuit = circuit;
        }

        [HttpGet]
        public IActionResult GetAll()
        {
            var roles = _roleManager.GetAll();
            IEnumerable<RoleModelResponse> result = roles.Select(role => new RoleModelResponse(role));
            return Ok(result);
        }

        [HttpGet("pharmacy-status")]
        public async Task<IActionResult> PharmacyStatus(CancellationToken cancellationToken)
        {
            try
            {
                var isUp = await _pharmacyServiceClient.PingAsync(cancellationToken);
                return isUp
                    ? Ok(new { status = "ok", pharmacyService = "up" })
                    : StatusCode(503, new { status = "error", pharmacyService = "down" });
            }
            catch (BrokenCircuitException)
            {
                return StatusCode(503, new { status = "error", pharmacyService = "circuit_open" });
            }
            catch (TimeoutRejectedException)
            {
                return StatusCode(503, new { status = "error", pharmacyService = "timeout" });
            }
            catch (HttpRequestException)
            {
                return StatusCode(503, new { status = "error", pharmacyService = "unreachable" });
            }
            finally
            {
                Response.Headers["X-Circuit-State"] = _circuit.CircuitState.ToString().ToLowerInvariant();
            }
        }

        [HttpGet("test")]
        public IActionResult Test()
        {
            // Endpoint simple de prueba que siempre devuelve 200
            return Ok(new { status = "ok", message = "Service is healthy" });
        }

        [HttpGet("ping")]
        public IActionResult Ping()
        {
            // Endpoint simple de prueba que siempre devuelve 200 - sin dependencias
            return Ok(new { status = "ok", message = "pong", timestamp = DateTime.UtcNow });
        }

    }
}

