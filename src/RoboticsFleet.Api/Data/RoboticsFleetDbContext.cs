using Microsoft.EntityFrameworkCore;

namespace RoboticsFleet.Api.Data;

public sealed class RoboticsFleetDbContext(DbContextOptions<RoboticsFleetDbContext> options)
    : DbContext(options)
{
    public DbSet<Message> Messages => Set<Message>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var message = modelBuilder.Entity<Message>();

        message.ToTable("Messages", "dbo", table =>
        {
            table.HasCheckConstraint("CK_Messages_Status_ReceivedAt", """
                ([Status] = 0 AND [ReceivedAt] IS NULL) OR
                ([Status] = 1 AND [ReceivedAt] IS NOT NULL)
                """);
            table.HasCheckConstraint("CK_Messages_UtcTimestamps", """
                DATEPART(TZOFFSET, [CreatedAt]) = 0 AND
                ([ReceivedAt] IS NULL OR DATEPART(TZOFFSET, [ReceivedAt]) = 0)
                """);
        });

        message.HasKey(record => record.MessageId)
            .HasName("PK_Messages")
            .IsClustered();

        message.Property(record => record.MessageId)
            .HasColumnType("uniqueidentifier")
            .ValueGeneratedNever();

        message.Property(record => record.Content)
            .HasColumnType("nvarchar(max)")
            .IsRequired();

        message.Property(record => record.Status)
            .HasConversion<byte>()
            .HasColumnType("tinyint");

        message.Property(record => record.CreatedAt).HasColumnType("datetimeoffset(7)");
        message.Property(record => record.ReceivedAt).HasColumnType("datetimeoffset(7)");
    }
}
