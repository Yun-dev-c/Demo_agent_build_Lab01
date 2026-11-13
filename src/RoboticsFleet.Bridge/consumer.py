import json
import logging
import os
import signal

import rclpy
from confluent_kafka import Consumer, KafkaException, Producer
from example_interfaces.msg import String
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from rclpy.signals import SignalHandlerOptions


logger = logging.getLogger(__name__)


def forward_command(consumer, publisher, message):
    payload = message.value().decode("utf-8")
    message_id = json.loads(payload)["messageId"]
    publisher.publish(String(data=payload))

    # Commit after the local ROS publisher handoff.
    for partition in consumer.commit(message=message, asynchronous=False):
        if partition.error is not None:
            raise KafkaException(partition.error)

    logger.info(
        "Published locally and committed messageId=%s partition=%s offset=%s",
        message_id, message.partition(), message.offset(),
    )


def forward_receipt(producer, message):
    try:
        receipt = json.loads(message.data)
        if not isinstance(receipt, dict) or receipt.get("type") != "RECEIVED":
            raise ValueError("Expected a RECEIVED event")
        message_id = receipt["messageId"]
        if not isinstance(message_id, str) or not message_id:
            raise ValueError("Expected a messageId")
    except (ValueError, KeyError) as error:
        logger.warning("Ignored invalid ROS receipt: %s", error)
        return

    def report_delivery(error, record):
        if error is not None:
            logger.error("Kafka receipt delivery failed messageId=%s: %s", message_id, error)
        else:
            logger.info("Published robot.events messageId=%s partition=%s offset=%s",
                        message_id, record.partition(), record.offset())

    try:
        producer.produce("robot.events", key=message_id, value=message.data,
                         on_delivery=report_delivery)
    except (KafkaException, BufferError):
        logger.exception("Could not enqueue Kafka receipt messageId=%s", message_id)


def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    stopping = False

    def request_stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    # Keep ROS alive until an in-progress publish and commit finish.
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    consumer = None
    producer = None
    node = None
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    try:
        node = rclpy.create_node("robotics_fleet_bridge")
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        publisher = node.create_publisher(String, "/demo/commands", qos)
        bootstrap_servers = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:29092")
        producer = Producer({
            "bootstrap.servers": bootstrap_servers,
            "acks": "all",
            "message.timeout.ms": 5000,
        })
        node.create_subscription(
            String, "/demo/receipts", lambda message: forward_receipt(producer, message), qos,
        )
        consumer = Consumer({
            "bootstrap.servers": bootstrap_servers,
            "group.id": "robotics-fleet-bridge",
            "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
            "enable.auto.offset.store": False,
        })
        consumer.subscribe(["robot.commands"])
        logger.info("Forwarding robot.commands to /demo/commands")

        while not stopping:
            rclpy.spin_once(node, timeout_sec=0)
            producer.poll(0)
            message = consumer.poll(0.1)
            if stopping or message is None:
                continue
            if message.error():
                raise KafkaException(message.error())

            try:
                forward_command(consumer, publisher, message)
            except Exception:
                logger.error(
                    "Command handoff or commit failed at partition=%s offset=%s",
                    message.partition(), message.offset(),
                )
                raise
    except Exception:
        logger.exception("Bridge stopped after an error")
        return 1
    finally:
        try:
            if consumer is not None:
                consumer.close()
        finally:
            try:
                if producer is not None and (remaining := producer.flush(5)):
                    logger.error("Bridge stopped with %s unconfirmed Kafka receipts", remaining)
            finally:
                if node is not None:
                    node.destroy_node()
                rclpy.try_shutdown()

    logger.info("Bridge stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
