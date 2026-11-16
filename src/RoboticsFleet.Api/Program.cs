using Confluent.Kafka;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using RoboticsFleet.Api.Data;
using RoboticsFleet.Api.Messages;

var builder = WebApplication.CreateBuilder(args);

var connectionString = new SqlConnectionStringBuilder(
    builder.Configuration.GetConnectionString("RoboticsFleet")
        ?? throw new InvalidOperationException("Configure ConnectionStrings:RoboticsFleet."));

var sqlPassword = builder.Configuration["MSSQL_SA_PASSWORD"];
if (!string.IsNullOrEmpty(sqlPassword))
{
    connectionString.Password = sqlPassword;
}

builder.Services.AddDbContext<RoboticsFleetDbContext>(options =>
    options.UseSqlServer(connectionString.ConnectionString));
builder.Services.AddSingleton<IProducer<string, string>>(services =>
{
    var configuration = services.GetRequiredService<IConfiguration>();
    return new ProducerBuilder<string, string>(new ProducerConfig
    {
        BootstrapServers = configuration["Kafka:BootstrapServers"] ?? "127.0.0.1:9092",
        Acks = Acks.All,
        MessageTimeoutMs = 5000,
        AllowAutoCreateTopics = true
    }).Build();
});
builder.Services.AddProblemDetails();
builder.Services.AddHostedService<ReceiptConsumer>();

var app = builder.Build();

app.UseExceptionHandler(new ExceptionHandlerOptions
{
    StatusCodeSelector = GetErrorStatusCode
});

app.MapPost("/api/messages", MessageEndpoints.CreateAsync);
app.MapGet("/api/messages/{messageId}", MessageEndpoints.GetAsync);

app.Run();

static int GetErrorStatusCode(Exception exception)
{
    // EF may wrap the SqlClient failure. Managed SqlClient can report an outage as TCP provider error 35.
    for (Exception? error = exception; error is not null; error = error.InnerException)
    {
        if (error is SqlException sql && (sql.IsTransient || sql.Number is -2 or 0 or 35 or 53 or 11001))
        {
            return StatusCodes.Status503ServiceUnavailable;
        }
    }

    return StatusCodes.Status500InternalServerError;
}
