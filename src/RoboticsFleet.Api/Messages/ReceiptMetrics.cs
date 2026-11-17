using System.Diagnostics.Metrics;

namespace RoboticsFleet.Api.Messages;

internal sealed class ReceiptMetrics : IDisposable
{
    internal const string MeterName = "RoboticsFleet.Receipts";

    private readonly Meter meter = new(MeterName);
    private readonly Counter<long> processed;
    private readonly Counter<long> failures;
    private readonly Histogram<double> duration;
    private readonly ILogger<ReceiptMetrics> logger;
    private long lastSuccess;

    public ReceiptMetrics(ILogger<ReceiptMetrics> logger)
    {
        this.logger = logger;
        processed = meter.CreateCounter<long>("robotics_receipts_processed");
        failures = meter.CreateCounter<long>("robotics_receipts_failures");
        duration = meter.CreateHistogram<double>("robotics_receipt_processing_duration", "s",
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30]
            });
        meter.CreateObservableGauge("robotics_consumer_last_success_timestamp",
            () => Interlocked.Read(ref lastSuccess), "s");
    }

    internal void RecordSuccess(string outcome, double seconds)
    {
        Interlocked.Exchange(ref lastSuccess, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        try
        {
            processed.Add(1, new KeyValuePair<string, object?>("outcome", outcome));
            duration.Record(seconds);
        }
        catch (Exception error)
        {
            logger.LogWarning(error, "Could not record receipt success metrics.");
        }
    }

    internal void RecordFailure(string reason)
    {
        try
        {
            failures.Add(1, new KeyValuePair<string, object?>("reason", reason));
        }
        catch (Exception error)
        {
            logger.LogWarning(error, "Could not record receipt failure metrics.");
        }
    }

    public void Dispose() => meter.Dispose();
}
