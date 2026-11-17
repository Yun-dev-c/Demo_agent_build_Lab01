using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace RoboticsFleet.Api.Data;

internal sealed class SqlReadinessCheck(RoboticsFleetDbContext db) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        var settings = new SqlConnectionStringBuilder(db.Database.GetConnectionString())
        {
            ConnectTimeout = 2,
            ConnectRetryCount = 0,
            Pooling = false
        };

        // Bound the HTTP probe even if the driver's DNS or socket attempt ignores cancellation.
        await OpenConnectionAsync(settings.ConnectionString, cancellationToken).WaitAsync(cancellationToken);
        return HealthCheckResult.Healthy();
    }

    private static async Task OpenConnectionAsync(string connectionString, CancellationToken cancellationToken)
    {
        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
    }
}
