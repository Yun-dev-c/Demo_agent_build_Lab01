namespace RoboticsFleet.Api.Data;

public sealed class Message
{
    public Guid MessageId { get; init; } = Guid.NewGuid();
    public required string Content { get; init; }
    public MessageStatus Status { get; set; } = MessageStatus.Pending;
    public required DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? ReceivedAt { get; set; }
}
