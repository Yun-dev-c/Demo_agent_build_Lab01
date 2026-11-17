using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace RoboticsFleet.Api.Messages;

internal sealed class ReceiptConsumerHealth : IHealthCheck
{
    private static readonly TimeSpan StatisticsMaxAge = TimeSpan.FromSeconds(10);
    private volatile Snapshot snapshot = new(State.Starting, false, 0);

    internal void ObserveStatistics(string statistics)
    {
        if (snapshot.Lifecycle is State.Faulted or State.Stopped)
        {
            return;
        }

        using var document = JsonDocument.Parse(statistics);
        var root = document.RootElement;
        var group = root.GetProperty("cgrp");
        var assigned = group.GetProperty("state").GetString() == "up" &&
            group.GetProperty("assignment_size").GetInt32() > 0;
        var connected = root.GetProperty("brokers").EnumerateObject().Any(broker =>
            broker.Value.GetProperty("nodeid").GetInt32() >= 0 &&
            broker.Value.GetProperty("state").GetString() == "UP");

        snapshot = new(State.Running, assigned && connected, Stopwatch.GetTimestamp());
    }

    internal void MarkFaulted() => snapshot = new(State.Faulted, false, 0);

    internal void MarkStopped()
    {
        if (snapshot.Lifecycle != State.Faulted)
        {
            snapshot = new(State.Stopped, false, 0);
        }
    }

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(GetHealth());

    internal HealthCheckResult GetHealth()
    {
        var current = snapshot;
        return current.Lifecycle switch
        {
            State.Running when Stopwatch.GetElapsedTime(current.ObservedAt) > StatisticsMaxAge =>
                HealthCheckResult.Unhealthy("Consumer statistics are stale."),
            State.Running when current.ConnectedAndAssigned => HealthCheckResult.Healthy(),
            State.Running => HealthCheckResult.Unhealthy("Consumer broker connection or assignment is unavailable."),
            _ => HealthCheckResult.Unhealthy($"Consumer is {current.Lifecycle}.")
        };

    }

    private enum State { Starting, Running, Faulted, Stopped }

    private sealed record Snapshot(State Lifecycle, bool ConnectedAndAssigned, long ObservedAt);
}
