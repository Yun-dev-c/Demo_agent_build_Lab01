using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace RoboticsFleet.Api.Migrations
{
    /// <inheritdoc />
    public partial class InitialMessages : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.EnsureSchema(
                name: "dbo");

            migrationBuilder.CreateTable(
                name: "Messages",
                schema: "dbo",
                columns: table => new
                {
                    MessageId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    Content = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Status = table.Column<byte>(type: "tinyint", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset(7)", nullable: false),
                    ReceivedAt = table.Column<DateTimeOffset>(type: "datetimeoffset(7)", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Messages", x => x.MessageId)
                        .Annotation("SqlServer:Clustered", true);
                    table.CheckConstraint("CK_Messages_Status_ReceivedAt", "([Status] = 0 AND [ReceivedAt] IS NULL) OR\n([Status] = 1 AND [ReceivedAt] IS NOT NULL)");
                    table.CheckConstraint("CK_Messages_UtcTimestamps", "DATEPART(TZOFFSET, [CreatedAt]) = 0 AND\n([ReceivedAt] IS NULL OR DATEPART(TZOFFSET, [ReceivedAt]) = 0)");
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "Messages",
                schema: "dbo");
        }
    }
}
