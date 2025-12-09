#!/usr/bin/python3.10
import argparse
import json
import sys
import urllib.error
import urllib.request

"""
飞书通知脚本 - 发送 SSL 证书部署结果到飞书机器人

Usage:
    python3 notify-feishu.py --webhook "URL" --success "ip1,ip2" --failed "ip3" --domain "example.com"

时间复杂度: O(1)
空间复杂度: O(1)
"""
# ======================== 配置 ========================

REQUEST_TIMEOUT = 5  # 秒


# ======================== 核心函数 ========================


def send_feishu_notification(
        webhook_url: str,
        domain: str,
        success_servers: list[str],
        failed_servers: list[str],
) -> bool:
    """
    发送部署结果到飞书机器人

    Args:
        webhook_url: 飞书 Webhook URL
        domain: 域名
        success_servers: 成功的服务器 IP 列表
        failed_servers: 失败的服务器 IP 列表

    Returns:
        bool: 发送成功返回 True，否则 False

    Raises:
        无，所有异常内部捕获并打印日志
    """
    total_success = len(success_servers)
    total_failed = len(failed_servers)

    # 根据是否有失败决定卡片颜色
    header_color = "red" if total_failed > 0 else "green"

    # 构建飞书卡片消息
    payload = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {"tag": "plain_text", "content": "SSL 证书部署报告"},
                "template": header_color,
            },
            "elements": [
                {
                    "tag": "div",
                    "text": {
                        "tag": "lark_md",
                        "content": f"**域名**: {domain}",
                    },
                },
                {
                    "tag": "div",
                    "fields": [
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**成功**: {total_success} 台",
                            },
                        },
                        {
                            "is_short": True,
                            "text": {
                                "tag": "lark_md",
                                "content": f"**失败**: {total_failed} 台",
                            },
                        },
                    ],
                },
                {"tag": "hr"},
                {
                    "tag": "div",
                    "text": {
                        "tag": "lark_md",
                        "content": f"**成功列表**: {', '.join(success_servers) or '无'}",
                    },
                },
                {
                    "tag": "div",
                    "text": {
                        "tag": "lark_md",
                        "content": f"**失败列表**: {', '.join(failed_servers) or '无'}",
                    },
                },
            ],
        },
    }

    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as response:
            result = json.loads(response.read().decode("utf-8"))

            # 飞书返回 code=0 表示成功
            if result.get("code") == 0:
                print(f"[INFO] 飞书通知发送成功")
                return True
            else:
                print(f"[ERROR] 飞书 API 返回错误: {result}", file=sys.stderr)
                return False

    except urllib.error.URLError as e:
        print(f"[ERROR] 飞书通知发送失败 (网络错误): {e}", file=sys.stderr)
        return False
    except json.JSONDecodeError as e:
        print(f"[ERROR] 飞书响应解析失败: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[ERROR] 飞书通知发送失败: {e}", file=sys.stderr)
        return False


def parse_server_list(servers_str: str) -> list[str]:
    """
    解析逗号分隔的服务器列表

    Args:
        servers_str: 逗号分隔的 IP 字符串，如 "192.168.1.1,192.168.1.2"

    Returns:
        list[str]: IP 列表，空字符串返回空列表
    """
    if not servers_str or not servers_str.strip():
        return []
    return [s.strip() for s in servers_str.split(",") if s.strip()]


# ======================== 主入口 ========================


def main() -> int:
    """
    主函数

    Returns:
        int: 0 成功, 1 失败
    """
    parser = argparse.ArgumentParser(
        description="发送 SSL 证书部署结果到飞书",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=
        """
        示例:
            python3 notify-feishu.py \\
                --webhook "https://open.feishu.cn/open-apis/bot/v2/hook/e414fe77-185e-4701-bfbd-e721c5d39806" \\
                --success "192.168.1.1,192.168.1.2" \\
                --failed "192.168.1.3" \\
                --domain "*.example.com"
        """,
    )

    parser.add_argument(
        "--webhook",
        required=True,
        help="飞书 Webhook URL",
    )
    parser.add_argument(
        "--success",
        default="",
        help="成功的服务器列表(逗号分隔)",
    )
    parser.add_argument(
        "--failed",
        default="",
        help="失败的服务器列表(逗号分隔)",
    )
    parser.add_argument(
        "--domain",
        default="unknown",
        help="域名",
    )

    args = parser.parse_args()

    success_servers = parse_server_list(args.success)
    failed_servers = parse_server_list(args.failed)

    if send_feishu_notification(args.webhook, args.domain, success_servers, failed_servers):
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
