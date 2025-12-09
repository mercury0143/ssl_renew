#!/usr/bin/python3.10
import os
import sys
import time
from pathlib import Path

from alibabacloud_alidns20150109 import models as alidns_models
from alibabacloud_alidns20150109.client import Client as AlidnsClient
from alibabacloud_tea_openapi import models as open_api_models

"""
certbot DNS-01 验证 - 添加 TXT 记录
"""


def load_config() -> dict[str, str]:
    """加载配置文件"""
    config: dict[str, str] = {}
    config_path = Path(__file__).parent / 'config.env'
    if not config_path.exists():
        return config
    for line in config_path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, _, value = line.partition('=')
            config[key.strip()] = value.strip().strip('"').strip("'")
    return config


def get_client() -> AlidnsClient:
    """创建阿里云 DNS 客户端"""
    cfg = load_config()
    return AlidnsClient(open_api_models.Config(
        access_key_id=cfg['ALICLOUD_ACCESS_KEY'],
        access_key_secret=cfg['ALICLOUD_SECRET_KEY'],
        region_id=cfg.get('ALICLOUD_REGION', 'cn-hangzhou'),
        endpoint=f"alidns.{cfg.get('ALICLOUD_REGION', 'cn-hangzhou')}.aliyuncs.com"
    ))


def main() -> int:
    domain = os.environ.get('CERTBOT_DOMAIN', '')
    validation = os.environ.get('CERTBOT_VALIDATION', '')
    if not domain or not validation:
        print("错误: 缺少 CERTBOT_DOMAIN 或 CERTBOT_VALIDATION")
        return 1

    # 解析域名: example.com -> (_acme-challenge, example.com)
    parts = domain.split('.')
    main_domain = '.'.join(parts[-2:])
    rr = f"_acme-challenge.{'.'.join(parts[:-2])}" if len(parts) > 2 else "_acme-challenge"

    print(f"添加 TXT 记录: {rr}.{main_domain} = {validation}")

    client = get_client()

    # 删除旧记录(如果存在)
    try:
        resp = client.describe_domain_records(alidns_models.DescribeDomainRecordsRequest(
            domain_name=main_domain, rrkey_word=rr, type='TXT'
        ))
        if resp.body.domain_records and resp.body.domain_records.record:
            for rec in resp.body.domain_records.record:
                if rec.rr == rr:
                    client.delete_domain_record(alidns_models.DeleteDomainRecordRequest(record_id=rec.record_id))
    except Exception:
        pass

    # 添加新记录
    client.add_domain_record(alidns_models.AddDomainRecordRequest(
        domain_name=main_domain, rr=rr, type='TXT', value=validation, ttl=600
    ))
    print("TXT 记录添加成功")

    # 等待 DNS 传播
    wait = int(load_config().get('DNS_PROPAGATION_WAIT', '60'))
    print(f"等待 {wait} 秒...")
    time.sleep(wait)

    return 0


if __name__ == '__main__':
    sys.exit(main())
