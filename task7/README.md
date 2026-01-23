# 1. Коллекция orders
## Схема
```js
{
  _id: ObjectId,        // order_id
  user_id: ObjectId,    // идентификатор клиента
  created_at: Date,

  items: [
    {
      product_id: ObjectId,
      category: String,
      price: Number,
      quantity: Number
    }
  ],

  status: String,
  total_amount: Number,
  geo_zone: String
}
```

## Индексы
```js
{ user_id: 1, created_at: -1 }  // история заказов пользователя
{ _id: 1 }          // получение статуса заказа
```

## Стратегия шардирования

**Шард-ключ:** `{ user_id: "hashed" }`

**Тип шардирования:** Хэшированное шардирование (based sharding)

**Обоснование:**
- все заказы одного пользователя находятся в одном шарде
- hash даёт равномерное распределение записей и устраняет hot-shard при массовом создании заказов.
- по гео было бы неравномерное распределение

## Команды MongoDB
```js
 // включаем шардирование БД
sh.enableSharding("mobile_world")

use mobile_world

// индекс под shard key
db.orders.createIndex({ user_id: "hashed" })

db.orders.createIndex({ user_id: 1, created_at: -1 })
db.orders.createIndex({ _id: 1 })

// включаем шардирование коллекции
sh.shardCollection(
  "mobile_world.orders",
  { user_id: "hashed" }
)
```

# 2. Коллекция products
```js
{
  _id: ObjectId,        // product_id
  name: String,
  category: String,
  price: Number,

  stock_by_geo: [
    {
      geo_zone: String,
      stock: Number
    }
  ],

  attributes: {
    color: String,
    size: String
  }
}
```

## Индексы
```js
{ category: 1, price: 1 }                           // поиск и фильтрация
{ _id: 1 }                                          // страница товара
{ stock_by_geo.geo_zone: 1, stock_by_geo.stock: 1 } // остатки
```

## Стратегия шардирования

**Шард-ключ:** `{ category: 1, _id: "hashed" }`

**Тип шардирования:** range + hash

*Это compound shard key*, где:
- первый ключ отвечает за локализацию запросов
- второй — за баланс нагрузки

**Обоснование:**
- только { _id: "hashed" } → плохо для поиска по категориям
- category (range) — группирует товары логически (каталог)
- _id (hashed) — равномерно распределяет товары внутри категории
- удобный поиск по category
- массовые обновления остатков → нет перегрузки одного шарда

## Команды MongoDB
```js
use mobile_world

db.products.createIndex({ _id: 1 })
db.products.createIndex({ "stock_by_geo_zone.geo_zone": 1, "stock_by_geo_zone.stock": 1 })

// индекс должен совпадать с shard key
db.products.createIndex({ category: 1, _id: "hashed" })

// шардирование коллекции
sh.shardCollection(
  "mobile_world.products",
  { category: 1, _id: "hashed" }
)
```

# 3. Коллекция carts
```js
{
  _id: ObjectId,                  // cart_id

  user_id: ObjectId | null,
  session_id: String | null,

  items: [
    {
      product_id: ObjectId,
      quantity: Number
    }
  ],

  status: "active" | "ordered" | "abandoned",

  created_at: Date,
  updated_at: Date,
  expires_at: Date
}
```

## Индексы
```js
{ user_id: 1, status: 1 }
{ session_id: 1, status: 1 }
{ expires_at: 1 }
```

## Стратегия шардирования

**Шард-ключ:** 
- `{ session_id: "hashed" }` - если гостевые корзины составляют большую часть трафика
- `{ user_id: "hashed" }` - подходит, если >80% трафика — авторизованные пользователи.
**Тип шардирования:** hash 

**Обоснование:**
- Каждая сессия независимо распределяется по шардам → высокая write-нагрузка масштабируется линейно.

## Команды MongoDB
```js
use mobile_world

db.carts.createIndex({ user_id: 1, status: 1 })
db.carts.createIndex({ session_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 })

// индекс под shard key
db.carts.createIndex({ session_id: "hashed" })

// включаем шардирование
sh.shardCollection(
  "mobile_world.carts",
  { session_id: "hashed" }
)
```