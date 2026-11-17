using System.Text.Json;
using Confluent.Kafka;
using Microsoft.EntityFrameworkCore;
using RoboticsFleet.Api.Data;

namespace RoboticsFleet.Api.Messages;

internal sealed class ReceiptConsumer(
    IConfiguration configuration, IServiceScopeFactory scopeFactory, ReceiptConsumerHealth health,
    ILogger<ReceiptConsumer> logger)
    : BackgroundService
{
    private const string Topic = "robot.events";
    private const string Group = "robotics-fleet-receipts";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        IConsumer<string, string>? consumer = null;
        ConsumeResult<string, string>? record = null;
        try
        {
            consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
            {
                BootstrapServers = configuration["Kafka:BootstrapServers"] ?? "127.0.0.1:9092",
                GroupId = Group,
                AutoOffsetReset = AutoOffsetReset.Earliest,
                EnableAutoCommit = false,
                EnableAutoOffsetStore = false,
                AllowAutoCreateTopics = true,
                StatisticsIntervalMs = 2000
            }).SetStatisticsHandler((_, statistics) => health.ObserveStatistics(statistics)).Build();
            consumer.Subscribe(Topic);
            logger.LogInformation("Consuming {Topic} as {Group}", Topic, Group);
            while (!stoppingToken.IsCancellationRequested)
            {
                record = null;
                record = consumer.Consume(stoppingToken);
                var (messageId, receivedAt) = ParseReceipt(record.Message.Key, record.Message.Value);
                await PersistReceiptAsync(messageId, receivedAt, stoppingToken);
                stoppingToken.ThrowIfCancellationRequested();
                consumer.Commit(record);
                logger.LogInformation("Committed receipt {MessageId} at {Offset}", messageId, record.TopicPartitionOffset);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Closing leaves unfinished work available for redelivery.
        }
        catch (Exception error)
        {
            health.MarkFaulted();
            // Stop consuming so a later record cannot commit past the failed offset.
            logger.LogError(error, "Receipt consumer halted at {Offset}. Restart after resolving the failure.",
                record?.TopicPartitionOffset);
        }
        finally
        {
            health.MarkStopped();
            try
            {
                consumer?.Close();
            }
            catch (KafkaException error)
            {
                health.MarkFaulted();
                logger.LogWarning(error, "Could not close the receipt consumer cleanly.");
            }
            finally
            {
                consumer?.Dispose();
            }
        }
    }

    private async Task PersistReceiptAsync(Guid messageId, DateTimeOffset receivedAt, CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<RoboticsFleetDbContext>();
        var matching = db.Messages.Where(message => message.MessageId == messageId);
        var updated = await matching.Where(message => message.Status == MessageStatus.Pending)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(message => message.Status, MessageStatus.Acknowledged)
                .SetProperty(message => message.ReceivedAt, (DateTimeOffset?)receivedAt), cancellationToken);

        if (updated == 1)
        {
            logger.LogInformation("Acknowledged message {MessageId} at {ReceivedAt}", messageId, receivedAt);
            return;
        }

        var status = await matching.Select(message => (MessageStatus?)message.Status)
            .SingleOrDefaultAsync(cancellationToken);
        switch (status)
        {
            case null:
                logger.LogWarning("Unmatched receipt for {MessageId}", messageId);
                break;
            case MessageStatus.Acknowledged:
                logger.LogInformation("Duplicate receipt for {MessageId}; keeping first timestamp", messageId);
                break;
            default:
                throw new InvalidOperationException($"Unexpected status after updating receipt {messageId}.");
        }
    }

    private static (Guid MessageId, DateTimeOffset ReceivedAt) ParseReceipt(string? key, string? payload)
    {
        if (payload is null)
        {
            throw new JsonException("Receipt payload is missing.");
        }

        using var document = JsonDocument.Parse(payload);
        var receipt = document.RootElement;
        if (receipt.ValueKind != JsonValueKind.Object ||
            ReadString(receipt, "type") != "RECEIVED" ||
            ReadString(receipt, "source") != "ros2-simulator")
        {
            throw new JsonException("Expected a RECEIVED event from ros2-simulator.");
        }

        var id = ReadString(receipt, "messageId");
        if (!Guid.TryParseExact(id, "D", out var messageId) || messageId.Version != 4 ||
            messageId.ToString("D") != id || id[19] is not ('8' or '9' or 'a' or 'b') || key != id)
        {
            throw new JsonException("Receipt messageId must be a canonical UUID v4 that matches the Kafka key.");
        }

        if (!receipt.TryGetProperty("receivedAt", out var timestamp) ||
            timestamp.ValueKind != JsonValueKind.String || !timestamp.GetString()!.EndsWith('Z') ||
            !timestamp.TryGetDateTimeOffset(out var receivedAt))
        {
            throw new JsonException("Receipt receivedAt must be a UTC timestamp ending in Z.");
        }

        return (messageId, receivedAt);
    }

    private static string? ReadString(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
