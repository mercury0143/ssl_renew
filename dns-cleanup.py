#!/usr/bin/python3.10
import sys

"""
certbot DNS-01 验证 - 清理钩子(空操作)

说明：
    dns-auth.py 已实现"先删后加"的覆盖逻辑，无需额外清理。
    保留 _acme-challenge TXT 记录不会有任何影响。
    此脚本保留为空操作，避免误删除风险。

时间复杂度: O(1)
空间复杂度: O(1)
"""


def main() -> int:
    """
    清理钩子 - 空操作
    
    Returns:
        int: 始终返回 0（成功）
    """
    print("[INFO] dns-cleanup: 跳过清理(dns-auth 已实现覆盖逻辑)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
