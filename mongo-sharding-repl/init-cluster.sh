#!/bin/bash

echo "1. Запускаем все контейнеры кроме mongos и api..."
docker-compose up -d config1 config2 config3 \
  shard1-primary shard1-secondary1 shard1-secondary2 \
  shard2-primary shard2-secondary1 shard2-secondary2

echo "2. Ждем 20 секунд для запуска MongoDB..."
sleep 20

echo "3. Инициализируем config replica set..."
docker exec config1 mongosh --port 27017 --eval "
rs.initiate({
  _id: 'configrs',
  configsvr: true,
  members: [
    { _id: 0, host: 'config1:27017' },
    { _id: 1, host: 'config2:27017' },
    { _id: 2, host: 'config3:27017' }
  ]
})
"

echo "4. Инициализируем shard1 replica set..."
docker exec shard1-primary mongosh --port 27018 --eval "
rs.initiate({
  _id: 'shard1rs',
  members: [
    { _id: 0, host: 'shard1-primary:27018' },
    { _id: 1, host: 'shard1-secondary1:27018' },
    { _id: 2, host: 'shard1-secondary2:27018' }
  ]
})
"

echo "5. Инициализируем shard2 replica set..."
docker exec shard2-primary mongosh --port 27019 --eval "
rs.initiate({
  _id: 'shard2rs',
  members: [
    { _id: 0, host: 'shard2-primary:27019' },
    { _id: 1, host: 'shard2-secondary1:27019' },
    { _id: 2, host: 'shard2-secondary2:27019' }
  ]
})
"

echo "6. Ждем 10 секунд для стабилизации репликасетов..."
sleep 10

echo "7. Запускаем mongos router..."
docker-compose up -d mongos_router

echo "8. Ждем 10 секунд для запуска mongos..."
sleep 10

echo "9. Добавляем шарды в mongos..."
docker exec mongos_router mongosh --port 27020 --eval "
try {
  sh.addShard('shard1rs/shard1-primary:27018');
  print('✓ Added shard1');
} catch(e) {
  print('Shard1 already added or error: ' + e.message);
}

try {
  sh.addShard('shard2rs/shard2-primary:27019');
  print('✓ Added shard2');
} catch(e) {
  print('Shard2 already added or error: ' + e.message);
}

// Включаем шардирование для базы данных
print('Enabling sharding for database somedb...');
try {
  sh.enableSharding('somedb');
  print('✓ Sharding enabled for somedb');
} catch(e) {
  print('Sharding already enabled or error: ' + e.message);
}

// Создаем и шардируем коллекцию
print('Creating and sharding collection helloDoc...');
try {
  sh.shardCollection('somedb.helloDoc', { name: 'hashed' });
  print('✓ Collection helloDoc sharded');
} catch(e) {
  print('Collection already sharded or error: ' + e.message);
}

// Проверяем статус
print('\\n=== Sharding Status ===');
printjson(sh.status());
"

echo "Ждем 5 секунд..."
sleep 5

echo "10. Запускаем API приложение..."
docker-compose up -d pymongo_api

echo "11. Готово! Проверяем статус:"
docker exec mongos_router mongosh --port 27020 --eval "sh.status()"