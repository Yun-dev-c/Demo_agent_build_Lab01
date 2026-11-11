using System.Text.Json;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;
using Microsoft.Net.Http.Headers;
using RoboticsFleet.Api.Data;

namespace RoboticsFleet.Api.Messages;

internal static class MessageEndpoints
{
    internal static async Task<IResult> CreateAsync(
        HttpContext context, RoboticsFleetDbContext db, IConfiguration configuration, CancellationToken cancellationToken)
    {
        var request = context.Request;
        if (context.Features.Get<IHttpRequestBodyDetectionFeature>()?.CanHaveBody == false)
        {
            return Results.BadRequest();
        }

        if (!MediaTypeHeaderValue.TryParse(request.ContentType, out var mediaType) ||
            !mediaType.MediaType.Equals("application/json", StringComparison.OrdinalIgnoreCase))
        {
            return Results.StatusCode(StatusCodes.Status415UnsupportedMediaType);
        }

        CreateMessageRequest? input;
        try
        {
            input = await request.ReadFromJsonAsync<CreateMessageRequest>(cancellationToken);
        }
        catch (JsonException)
        {
            return Results.BadRequest();
        }
        catch (InvalidOperationException)
        {
            return Results.StatusCode(StatusCodes.Status415UnsupportedMediaType);
        }

        if (string.IsNullOrWhiteSpace(input?.Content))
        {
            return Results.BadRequest();
        }

        if (!configuration.GetValue<bool>("Lab3:SqlOnlyPost"))
        {
            return Results.Problem(
                statusCode: StatusCodes.Status503ServiceUnavailable,
                detail: "Command publication is unavailable.");
        }

        var message = new Message { Content = input.Content, CreatedAt = DateTimeOffset.UtcNow };
        db.Messages.Add(message);
        await db.SaveChangesAsync(cancellationToken);

        // Lab 4 will publish this persisted message and return 201 after Kafka acknowledges it.
        context.Response.Headers.Location = $"/api/messages/{message.MessageId:D}";
        context.Response.Headers["X-Lab-Mode"] = "sql-only";
        return Results.Ok(MessageResponse.From(message));
    }

    internal static async Task<IResult> GetAsync(
        string messageId, RoboticsFleetDbContext db, CancellationToken cancellationToken)
    {
        if (!Guid.TryParseExact(messageId, "D", out var id) || id.Version != 4 ||
            id.ToString("D") != messageId || messageId[19] is not ('8' or '9' or 'a' or 'b'))
        {
            return Results.BadRequest();
        }

        var message = await db.Messages.AsNoTracking().SingleOrDefaultAsync(
            record => record.MessageId == id, cancellationToken);
        return message is null ? Results.NotFound() : Results.Ok(MessageResponse.From(message));
    }

    private sealed record CreateMessageRequest(string? Content);

    private sealed record MessageResponse(
        Guid MessageId, string Content, string Status, DateTime CreatedAt, DateTime? ReceivedAt)
    {
        internal static MessageResponse From(Message message) => new(
            message.MessageId, message.Content, message.Status.ToString(),
            message.CreatedAt.UtcDateTime, message.ReceivedAt?.UtcDateTime);
    }
}
