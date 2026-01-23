## Запускаем все по порядку
```shell
# Даем права на выполнение
chmod +x init-cluster.sh mongo-init.sh

# 1. Запускаем 
./init-cluster.sh

# 2 Заполняем данными
./mongo-init.sh
```

## Проверить кеширование
```shell
# Первый раз (без кеша) медленнее
time curl http://localhost:8080/helloDoc/users

# Второй раз (с кешем) быстрее
time curl http://localhost:8080/helloDoc/users

# Очистка кеша
docker compose exec redis redis-cli FLUSHALL
```