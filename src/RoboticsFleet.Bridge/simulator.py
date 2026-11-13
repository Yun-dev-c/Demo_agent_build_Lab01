import json
from datetime import datetime, timezone
from uuid import UUID

import rclpy
from example_interfaces.msg import String
from rclpy.executors import ExternalShutdownException
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy


def main():
    rclpy.init()
    node = rclpy.create_node("robotics_fleet_simulator")
    try:
        qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        publisher = node.create_publisher(String, "/demo/receipts", qos)

        def receive_command(message):
            received_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            try:
                command = json.loads(message.data)
                if not isinstance(command, dict) or command.get("type") != "PING":
                    raise ValueError("Expected a PING command")
                message_id = command["messageId"]
                if not isinstance(message_id, str):
                    raise ValueError("Expected a UUID v4 messageId")
                identifier = UUID(message_id)
                if identifier.version != 4 or str(identifier) != message_id:
                    raise ValueError("Expected a lowercase UUID v4 messageId")
            except (ValueError, KeyError) as error:
                node.get_logger().warning(f"Ignored invalid ROS command: {error}")
                return

            receipt = {
                "messageId": message_id,
                "type": "RECEIVED",
                "source": "ros2-simulator",
                "receivedAt": received_at,
            }
            publisher.publish(String(data=json.dumps(receipt, separators=(",", ":"))))
            node.get_logger().info(f"Published /demo/receipts messageId={message_id}")

        node.create_subscription(String, "/demo/commands", receive_command, qos)
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
