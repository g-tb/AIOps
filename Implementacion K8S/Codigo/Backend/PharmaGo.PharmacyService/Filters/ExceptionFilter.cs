using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Mvc;
using PharmaGo.Exceptions;

namespace PharmaGo.PharmacyService.Filters;
public class ExceptionFilter : IExceptionFilter
{
    private readonly ILogger<ExceptionFilter> _logger;

    public ExceptionFilter(ILogger<ExceptionFilter> logger)
    {
        _logger = logger;
    }

    public void OnException(ExceptionContext context)
    {
        // Pattern matching instead of rethrowing keeps the original stack trace in the log.
        switch (context.Exception)
        {
            case ResourceNotFoundException e:
                context.Result = new JsonResult(new { Message = e.Message }) { StatusCode = 404 };
                break;
            case InvalidResourceException e:
                context.Result = new JsonResult(new { Message = e.Message }) { StatusCode = 400 };
                break;
            case FormatException:
                context.Result = new JsonResult(new { Message = "Invalid token format" }) { StatusCode = 400 };
                break;
            default:
                // Only unexpected errors are logged: 404 and 400 are expected responses.
                _logger.LogError(context.Exception, "Unhandled exception on {Method} {Path}, responding 500",
                    context.HttpContext.Request.Method, context.HttpContext.Request.Path.Value);
                context.Result = new JsonResult(new { Message = context.Exception.Message }) { StatusCode = 500 };
                break;
        }
        context.ExceptionHandled = true;
    }
}
