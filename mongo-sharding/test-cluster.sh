#!/bin/bash

echo "=== Testing MongoDB Sharding Cluster ==="

# Проверка контейнеров
echo "1. Checking containers..."
docker ps --filter "name=mongo-sharding" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Проверка подключения к mongos_router
echo -e "\n2. Testing mongos_router connection..."
docker exec mongos_router mongosh --port 27020 --eval "
try {
  const ping = db.adminCommand({ ping: 1 });
  if (ping.ok === 1) {
    print('✓ mongos_router is responding');
  } else {
    print('✗ mongos_router not responding properly');
  }
} catch(e) {
  print('✗ Cannot connect to mongos_router: ' + e.message);
}
" --quiet

# Проверка шардов
echo -e "\n3. Checking shards..."
docker exec mongos_router mongosh --port 27020 --eval "
try {
  const shards = db.adminCommand({ listShards: 1 });
  if (shards.ok === 1) {
    print('✓ Number of shards: ' + shards.shards.length);
    shards.shards.forEach(shard => {
      print('  - ' + shard._id + ': ' + shard.host);
    });
  }
} catch(e) {
  print('✗ Cannot list shards: ' + e.message);
}
" --quiet

# Проверка нашей базы данных
echo -e "\n4. Testing our database..."
docker exec mongos_router mongosh --port 27020 somedb --eval "
try {
  // Проверяем существование коллекции
  const collections = db.getCollectionNames();
  const hasHelloDoc = collections.includes('helloDoc');
  
  if (hasHelloDoc) {
    print('✓ Collection helloDoc exists');
    
    // Вставляем тестовые данные
    const result = db.helloDoc.insertOne({
      name: 'test_user_' + Date.now(),
      message: 'Test document',
      timestamp: new Date()
    });
    
    print('✓ Test document inserted with ID: ' + result.insertedId);
    
    // Проверяем чтение
    const doc = db.helloDoc.findOne({ _id: result.insertedId });
    if (doc) {
      print('✓ Document successfully retrieved');
      
      // Проверяем статистику
      const stats = db.helloDoc.stats();
      print('✓ Collection is sharded: ' + stats.sharded);
      print('✓ Total documents: ' + stats.count);
      
      // Проверяем распределение по шардам
      print('\\nChecking shard distribution:');
      const shardDistribution = db.helloDoc.getShardDistribution();
      print(JSON.stringify(shardDistribution, null, 2));
    }
    
    // Очищаем тестовые данные
    db.helloDoc.deleteOne({ _id: result.insertedId });
    print('✓ Test document cleaned up');
    
  } else {
    print('✗ Collection helloDoc does not exist');
    print('Available collections: ' + JSON.stringify(collections));
  }
  
} catch(e) {
  print('✗ Database error: ' + e.message);
  print('Error details: ' + JSON.stringify(e));
}
" --quiet

echo -e "\n=== Test complete ==="