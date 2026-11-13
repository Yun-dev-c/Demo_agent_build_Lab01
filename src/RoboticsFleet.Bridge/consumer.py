import json
import logging
import os
import signal

import rclpy
from confluent_kafka import Consumer, KafkaException
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
    node = None
    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    try:
        node = rclpy.create_node("robotics_fleet_bridge")
        publisher = node.create_publisher(String, "/demo/commands", QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        ))
        consumer = Consumer({
            "bootstrap.servers": os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:29092"),
            "group.id": "robotics-fleet-bridge",
            "auto.offset.reset": "earliest",
            "enable.auto.commit": False,
            "enable.auto.offset.store": False,
        })
        consumer.subscribe(["robot.commands"])
        logger.info("Forwarding robot.commands to /demo/commands")

        while not stopping:
            message = consumer.poll(1.0)
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
            if node is not None:
                node.destroy_node()
            rclpy.try_shutdown()

    logger.info("Bridge stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
