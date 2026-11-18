using System.Diagnostics;
using System.Text.Json;
using Confluent.Kafka;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.EntityFrameworkCore;
using Microsoft.Net.Http.Headers;
using RoboticsFleet.Api.Data;

namespace RoboticsFleet.Api.Messages;

internal static class MessageEndpoints
{
    internal const string ActivitySourceName = "RoboticsFleet.Api.Commands";
    private const string CommandTopic = "robot.commands";
    private static readonly ActivitySource CommandActivitySource = new(ActivitySourceName);
    private static readonly JsonSerializerOptions CommandJson = new(JsonSerializerDefaults.Web);

    internal static async Task<IResult> CreateAsync(
        HttpContext context, RoboticsFleetDbContext db, IProducer<string, string> producer,
        ILoggerFactory loggerFactory, CancellationToken cancellationToken)
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

        var message = new Message { Content = input.Content, CreatedAt = DateTimeOffset.UtcNow };
        db.Messages.Add(message);
        using (var persistence = CommandActivitySource.StartActivity("INSERT Messages", ActivityKind.Client))
        {
            persistence?.SetTag("db.system.name", "microsoft.sql_server");
            persistence?.SetTag("db.operation.name", "INSERT");
            try
            {
                await db.SaveChangesAsync(cancellationToken);
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested || exception is not OperationCanceledException)
            {
                RecordFailure(persistence, exception);
                throw;
            }
        }

        var key = message.MessageId.ToString("D");
        var command = new RobotCommand(key, "PING", message.Content, message.CreatedAt.UtcDateTime);
        var logger = loggerFactory.CreateLogger(typeof(MessageEndpoints));
        using var publication = CommandActivitySource.StartActivity("publish robot.commands", ActivityKind.Producer);
        publication?.SetTag("messaging.system", "kafka");
        publication?.SetTag("messaging.destination.name", CommandTopic);
        publication?.SetTag("messaging.operation.name", "publish");
        try
        {
            // The SQL write is committed. Wait for the bounded delivery result even if the client disconnects.
            var delivery = await producer.ProduceAsync(CommandTopic, new Message<string, string>
            {
                Key = key,
                Value = JsonSerializer.Serialize(command, CommandJson)
            });

            if (delivery.Status == PersistenceStatus.Persisted)
            {
                return Results.Created($"/api/messages/{key}", MessageResponse.From(message));
            }

            publication?.SetStatus(ActivityStatusCode.Error, "Kafka delivery unconfirmed");
            logger.LogWarning("Kafka delivery for {MessageId} on {Topic} was {DeliveryStatus} after the SQL insert",
                key, CommandTopic, delivery.Status);
        }
        catch (KafkaException exception)
        {
            RecordFailure(publication, exception);
            logger.LogWarning(exception, "Kafka publication for {MessageId} on {Topic} failed after the SQL insert with {KafkaErrorCode}",
                key, CommandTopic, exception.Error.Code);
        }
        catch (Exception exception)
        {
            RecordFailure(publication, exception);
            throw;
        }

        return Results.Problem(
            statusCode: StatusCodes.Status503ServiceUnavailable,
            detail: "Command publication could not be confirmed.");
    }

    private static void RecordFailure(Activity? activity, Exception exception)
    {
        if (activity is null) { return; }

        // Exception messages and stack traces may expose request or connection details.
        var exceptionType = exception.GetType().FullName;
        activity.SetStatus(ActivityStatusCode.Error);
        activity.SetTag("error.type", exceptionType);
        activity.AddEvent(new ActivityEvent("exception", tags: new ActivityTagsCollection
        {
            { "exception.type", exceptionType }
        }));
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

    private sealed record RobotCommand(string MessageId, string Type, string Content, DateTime CreatedAt);

    private sealed record MessageResponse(
        Guid MessageId, string Content, string Status, DateTime CreatedAt, DateTime? ReceivedAt)
    {
        internal static MessageResponse From(Message message) => new(
            message.MessageId, message.Content, message.Status.ToString(),
            message.CreatedAt.UtcDateTime, message.ReceivedAt?.UtcDateTime);
    }
}
