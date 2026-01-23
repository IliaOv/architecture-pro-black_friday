## Запускаем все по порядку
```shell
# Даем права на выполнение
chmod +x init-cluster.sh mongo-init.sh

# 1. Запускаем 
./init-cluster.sh

# 2 Заполняем данными
./mongo-init.sh
```

## Ручная проверка работы
```shell
# Проверить статус контейнеров
docker-compose ps

# Проверить подключение к mongos
docker exec mongos_router mongosh --port 27020 --eval "db.adminCommand('ping')"

# Проверить статус всех репликасетов
docker exec -it shard1-primary mongosh --port 27018 --eval "rs.status()"
docker exec -it shard2-primary mongosh --port 27019 --eval "rs.status()"
```