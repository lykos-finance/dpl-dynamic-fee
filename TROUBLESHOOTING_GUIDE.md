# 🔍 Руководство по диагностике проблем с пулом Uniswap V4

## Быстрый старт: Проверка пула

### 1. Запустите диагностический скрипт

```bash
# Установите переменные окружения
export HOOK_ADDRESS_V5=0x...  # Ваш адрес хука
export PRIVATE_KEY=0x...       # Для чтения (не транзакций)

# Запустите диагностику
forge script script/DiagnosticV5.s.sol --rpc-url mainnet --broadcast
```

Скрипт проверит:
- ✅ Валидность адреса хука (флаги разрешений)
- ✅ Инициализацию пула
- ✅ Наличие ликвидности
- ✅ Состояние хука (паника/норма)
- ✅ Балансы токенов

---

## 🔴 Основные причины блокировки транзакций

### Причина #1: Завышенные комиссии (КРИТИЧНО)

**Симптом:** Транзакции ревертятся или никто не свапает

**Проблема:** В текущем VolatilityGuardHookV5.sol:
```solidity
uint24 public constant MIN_FEE   = 3000;  // 0.30% (должно быть 0.10%)
uint24 public constant PANIC_FEE = 10000; // 1.00% (должно быть 0.30%)
```

**Последствие:** Комиссия 1% убивает весь объем торгов.

**Решение:**
1. Используйте исправленную версию: `VolatilityGuardHookV5_Fixed.sol`
2. Или вручную измените константы:
   ```solidity
   uint24 public constant MIN_FEE   = 1000;  // 0.10%
   uint24 public constant PANIC_FEE = 3000;  // 0.30%
   ```
3. Передеплойте хук с правильными значениями

---

### Причина #2: Пул постоянно в режиме паники

**Симптом:** События `PanicActivated` каждые 5 минут

**Проблема:** Порог слишком низкий для волатильного актива:
```solidity
int24 public constant TICK_THRESHOLD = 60;  // ~0.6% изменения цены
```

Для ETH/USDT движение >0.6% — обычное явление каждые несколько минут.

**Решение:**
```solidity
int24 public constant TICK_THRESHOLD = 200;  // ~2% изменения цены
```

---

### Причина #3: Хук не инициализирован

**Симптом:** `revert: Pool not initialized` или постоянный PANIC_FEE

**Проблема:** В оригинальном коде нет проверки:
```solidity
function beforeSwap(...) {
    PoolState storage state = _states[poolId];
    // ❌ Если state.initialized == false, referenceTick == 0
    (, int24 currentTick,,) = poolManager.getSlot0(poolId);
    // delta будет огромным → постоянная паника
}
```

**Решение:** Используйте `VolatilityGuardHookV5_Fixed.sol` с проверкой:
```solidity
require(state.initialized, "Pool not initialized");
```

---

### Причина #4: Нет ликвидности в пуле

**Симптом:** `revert: Not enough liquidity`

**Диагностика:**
```bash
cast call $POOL_MANAGER "getLiquidity(bytes32)(uint128)" $POOL_ID
```

Если возвращает `0` → нет ликвидности.

**Решение:**
1. Проверьте, что InitPool.s.sol отработал успешно
2. Добавьте ликвидность через IncreaseLiquidity.s.sol
3. Убедитесь, что currentTick находится внутри диапазона ликвидности

---

### Причина #5: Неверные флаги адреса хука

**Симптом:** Транзакции ревертятся сразу в PoolManager

**Проблема:** Адрес хука должен иметь младшие 14 бит = `0x0082`:
- `0x0080` = BEFORE_SWAP_FLAG
- `0x0002` = AFTER_INITIALIZE_FLAG

**Диагностика:**
```bash
python3 -c "print(hex(int('$HOOK_ADDRESS_V5', 16) & 0x3FFF))"
```

Должно вернуть `0x82`.

**Решение:**
- Перемайните адрес с правильными флагами через HookMiner
- Или используйте существующий валидный адрес

---

### Причина #6: getSlot0 ревертится

**Симптом:** Все свопы падают с непонятной ошибкой

**Проблема:** В оригинальном коде нет обработки ошибок:
```solidity
(, int24 currentTick,,) = poolManager.getSlot0(poolId);
// Если вызов упадет → весь beforeSwap упадет
```

**Решение:** Используйте `VolatilityGuardHookV5_Fixed.sol` с try/catch:
```solidity
try poolManager.getSlot0(poolId) returns (uint160, int24 tick, uint24, uint8) {
    currentTick = tick;
} catch {
    return _return(MIN_FEE);  // fallback
}
```

---

## 🛠️ Пошаговый план исправления

### Шаг 1: Диагностика (5 минут)

```bash
# 1. Проверьте адрес хука
export HOOK_ADDRESS_V5=0x...
forge script script/DiagnosticV5.s.sol --rpc-url mainnet

# 2. Проверьте состояние пула
cast call $POOL_MANAGER "getSlot0(bytes32)" $POOL_ID

# 3. Проверьте ликвидность
cast call $POOL_MANAGER "getLiquidity(bytes32)" $POOL_ID
```

### Шаг 2: Исправление хука (30 минут)

**Вариант А: Используйте готовую исправленную версию**
```bash
# 1. Скопируйте VolatilityGuardHookV5_Fixed.sol в src/
# 2. Обновите DeployV5.s.sol:
#    type(VolatilityGuardHookV5).creationCode
#    →
#    type(VolatilityGuardHookV5_Fixed).creationCode

# 3. Передеплойте
forge script script/DeployV5.s.sol --rpc-url mainnet --broadcast --verify
```

**Вариант Б: Исправьте существующий хук вручную**

Откройте `src/VolatilityGuardHookV5.sol` и измените:

```diff
- uint24 public constant MIN_FEE   = 3000;  // 0.30%
- uint24 public constant PANIC_FEE = 10000; // 1.00%
- int24  public constant TICK_THRESHOLD = 60;
+ uint24 public constant MIN_FEE   = 1000;  // 0.10%
+ uint24 public constant PANIC_FEE = 3000;  // 0.30%
+ int24  public constant TICK_THRESHOLD = 200;
```

Добавьте проверку инициализации:
```diff
  function beforeSwap(...) {
      PoolState storage state = _states[poolId];
+     require(state.initialized, "Pool not initialized");
      
      (, int24 currentTick,,) = poolManager.getSlot0(poolId);
```

### Шаг 3: Повторная инициализация (если нужно)

Если текущий пул сломан:

```bash
# 1. Создайте новый пул с новым хуком
export HOOK_ADDRESS_V5=<новый адрес>
forge script script/InitPool.s.sol --rpc-url mainnet --broadcast

# 2. Добавьте ликвидность
forge script script/IncreaseLiquidity.s.sol --rpc-url mainnet --broadcast
```

### Шаг 4: Тестирование (10 минут)

```bash
# 1. Проверьте диагностику снова
forge script script/DiagnosticV5.s.sol --rpc-url mainnet

# 2. Выполните тестовый своп
export SWAP_DIR=buy
export AMOUNT_IN=1000000  # 1 USDT
forge script script/Swap.s.sol --rpc-url mainnet --broadcast

# 3. Проверьте события
cast logs --rpc-url mainnet --address $HOOK_ADDRESS_V5
```

---

## 📊 Сравнение версий хука

| Параметр | V5 Original | V5 Fixed | V3 |
|----------|-------------|----------|-----|
| MIN_FEE | 0.30% ❌ | 0.10% ✅ | 0.25% |
| PANIC_FEE | 1.00% ❌ | 0.30% ✅ | 0.30% |
| TICK_THRESHOLD | 60 ❌ | 200 ✅ | 60/150 |
| Проверка init | ❌ | ✅ | ✅ |
| Try/catch errors | ❌ | ✅ | ❌ |
| Защита от 2x init | ❌ | ✅ | ✅ |
| Flash-loan защита | ❌ | ❌ | ✅ |
| Продление паники | ❌ | ❌ | ✅ |
| Направленные комиссии | ❌ | ❌ | ✅ |

**Вывод:** Для production рекомендуется использовать **V3** или портировать его улучшения.

---

## 🔧 Полезные команды для отладки

### Чтение состояния пула
```bash
# Slot0 (price, tick, fees)
cast call $POOL_MANAGER "getSlot0(bytes32)(uint160,int24,uint24,uint8)" $POOL_ID

# Ликвидность
cast call $POOL_MANAGER "getLiquidity(bytes32)(uint128)" $POOL_ID

# Позиция (tickLower, tickUpper, liquidity)
cast call $POOL_MANAGER "getPosition(bytes32,address,int24,int24,bytes32)" \
  $POOL_ID $POSITION_OWNER $TICK_LOWER $TICK_UPPER 0x0
```

### Чтение состояния хука
```bash
# Режим паники
cast call $HOOK_ADDRESS_V5 "isPanicking(bytes32)(bool)" $POOL_ID

# Полное состояние (только для Fixed версии)
cast call $HOOK_ADDRESS_V5 "getState(bytes32)(int24,uint256,bool)" $POOL_ID
```

### Мониторинг событий
```bash
# Все события хука за последние 100 блоков
cast logs --rpc-url mainnet \
  --address $HOOK_ADDRESS_V5 \
  --from-block -100

# Фильтр по PanicActivated
cast logs --rpc-url mainnet \
  --address $HOOK_ADDRESS_V5 \
  --from-block -1000 \
  topic0 $(cast keccak "PanicActivated(bytes32,int24,int24,uint256)")
```

### Симуляция свопа (без отправки tx)
```bash
# Используйте cast call вместо cast send для тестирования
cast call --rpc-url mainnet \
  --from $YOUR_ADDRESS \
  $ROUTER_ADDRESS \
  "swapFrom(...)"
```

---

## ❓ FAQ

### Q: Почему свопы ревертятся с "Slippage exceeded"?

**A:** Два варианта:
1. Пул в режиме паники → высокая комиссия → меньше output
2. Недостаточно ликвидности в диапазоне текущей цены

**Решение:**
- Используйте `MIN_OUT=0` для теста без slippage protection
- Добавьте ликвидность в активный диапазон

---

### Q: Как проверить, что хук правильно примайнен?

**A:**
```bash
# Младшие 14 бит адреса должны быть 0x0082
python3 << EOF
addr = int("$HOOK_ADDRESS_V5", 16)
bits = addr & 0x3FFF
required = 0x0082
print(f"Address bits: {hex(bits)}")
print(f"Required:     {hex(required)}")
print(f"Valid:        {bits == required}")
EOF
```

---

### Q: Можно ли обновить хук без переинициализации пула?

**A:** **НЕТ.** В Uniswap V4:
- PoolKey включает адрес хука
- PoolId = keccak256(PoolKey)
- Изменение хука → изменение PoolId → новый пул

**Решение:**
- Деплойте новый хук
- Создавайте новый пул
- Мигрируйте ликвидность вручную

---

### Q: Как мониторить здоровье пула?

**A:** Используйте cron job:
```bash
# monitor.sh
#!/bin/bash
while true; do
  forge script script/DiagnosticV5.s.sol --rpc-url mainnet | \
    grep -E "BLOCKER|WARNING|HEALTHY"
  sleep 300  # каждые 5 минут
done
```

---

## 📞 Контакты и ресурсы

- 📖 [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- 🔗 [v4-core GitHub](https://github.com/Uniswap/v4-core)
- 🔗 [v4-periphery GitHub](https://github.com/Uniswap/v4-periphery)
- 💬 [Uniswap Discord](https://discord.gg/uniswap)

---

**Создано:** GitHub Copilot  
**Дата:** 21 мая 2026  
**Версия:** 1.0
