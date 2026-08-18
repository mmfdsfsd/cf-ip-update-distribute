使用说明

配置：

CF_API_TOKEN、ZONE_ID

SUBDOMAINS → 你要更新的子域名

MAX_IPS_PER_DOMAIN → 每个子域名挂几个 IP

执行：

chmod +x cf-ip-update-to-cf.sh
./cf-ip-update-to-cf.sh

可加入 cron 自动更新：

7 * * * * /bin/bash /root/cf-ip-update/cf-ip-update-to-cf.sh --cron >> /root/cf-ip-update/cf-ip-update-cron.log 2>&1
