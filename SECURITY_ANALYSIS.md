# Анализ безопасности VolatilityGuardHookV5

## Дата анализа: 21 мая 2026

## 🔴 КРИТИЧЕСКИЕ ПРОБЛЕМЫ

### 1. Несоответствие комиссий (БЛОКИРУЕТ ТРАНЗАКЦИИ)
**Файл:** `src/VolatilityGuardHookV5.sol:16-28`

**Проблема:**
- Комментарии: MIN_FEE = 0.10%, PANIC_FEE = 0.30%
- Реальный код: MIN_FEE = 0.30%, PANIC_FEE = 1.00%

**Последствия:**
- Комиссия 1% в режиме паники отпугивает арбитражеров
- Низкая ликвидность → широкие спреды → нет транзакций
- Пул может постоянно быть в режиме паники из-за низкого порога

**Решение:**
```solidity
// Исправить на реальные намерения:
uint24 public constant MIN_FEE   = 1000;  // 0.10%
uint24 public constant PANIC_FEE = 3000;  // 0.30%
```

---

### 2. Отсутствие проверки инициализации (ПОТЕНЦИАЛЬНЫЙ REVERT)
**Файл:** `src/VolatilityGuardHookV5.sol:81-95`

**Проблема:**
```solidity
function afterInitialize(...) {
    // ❌ Нет проверки: что если вызывается дважды?
    state.referenceTick = tick;
    state.initialized = true;
}
```

**Последствия:**
- Повторная инициализация перезапишет referenceTick
- Немедленная паника при первом свопе

**Решение:**
```solidity
function afterInitialize(...) {
    require(!state.initialized, "Already initialized");
    state.referenceTick = tick;
    state.panicExpiry = 0;
    state.initialized = true;
}
```

---

### 3. Нет проверки инициализации в beforeSwap (БЛОКИРУЕТ СВОПЫ)
**Файл:** `src/VolatilityGuardHookV5.sol:97-134`

**Проблема:**
```solidity
function beforeSwap(...) {
    PoolState storage state = _states[poolId];
    // ❌ Если state.initialized == false, referenceTick == 0
    (, int24 currentTick,,) = poolManager.getSlot0(poolId);
    // delta всегда будет огромным → постоянная паника
}
```

**Последствия:**
- Если beforeSwap вызвается раньше afterInitialize → PANIC_FEE всегда
- Пул непригоден для использования

**Решение:**
```solidity
function beforeSwap(...) {
    PoolState storage state = _states[poolId];
    require(state.initialized, "Pool not initialized");
    
    (, int24 currentTick,,) = poolManager.getSlot0(poolId);
    // ...
}
```

---

### 4. Отсутствие обработки ошибок getSlot0 (100% REVERT)
**Файл:** `src/VolatilityGuardHookV5.sol:106`

**Проблема:**
```solidity
(, int24 currentTick,,) = poolManager.getSlot0(poolId);
// Если вызов упадет → весь beforeSwap упадет → все свопы заблокированы
```

**Последствия:**
- Любая проблема с PoolManager блокирует ВСЕ транзакции
- Нет graceful degradation

**Решение:**
```solidity
try poolManager.getSlot0(poolId) returns (uint160, int24 tick, uint24, uint8) {
    currentTick = tick;
} catch {
    // Fallback: вернуть MIN_FEE при ошибке чтения
    return _return(MIN_FEE);
}
```

---

### 5. Неверная валидация адреса хука (DEPLOYMENT FAIL)
**Файл:** `script/DeployV5.s.sol:38-44`

**Проблема:**
```solidity
uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG);
// = 0x0082

require(uint160(predicted) & uint160(0x3FFF) == flags, "Wrong flags");
```

**Риск:**
- Если майнинг не найдет адрес с правильными битами за 500k итераций
- Deployment упадет, хук не задеплоится

**Решение:**
- Увеличить количество итераций до 5_000_000
- Добавить логирование прогресса
- Опциональный fallback на deterministic адрес

---

## 🟡 ПОТЕНЦИАЛЬНЫЕ ПРОБЛЕМЫ

### 6. Слишком низкий порог паники
**Файл:** `src/VolatilityGuardHookV5.sol:29`

```solidity
int24 public constant TICK_THRESHOLD = 60;  // ~0.6% price change
```

**Проблема для ETH/USDT:**
- ETH часто движется на >0.6% за минуту
- Пул будет ПОСТОЯННО в режиме паники
- Комиссия 1% убьет весь объем

**Рекомендация:**
```solidity
int24 public constant TICK_THRESHOLD = 200;  // ~2% для ETH (разумнее)
```

---

### 7. Паника без продления может быть слишком короткой
**Файл:** `src/VolatilityGuardHookV5.sol:30`

```solidity
uint256 public constant PANIC_DURATION = 300;  // 5 минут фиксированно
```

**Проблема:**
- Если волатильность продолжается, паника истекает
- Резкий переход 1.00% → 0.30% может вызвать арбитраж

**Рекомендация:**
- Добавить продление паники (как в V3)
- Или использовать TWAP-подобное сглаживание

---

### 8. Отсутствие проверки валидности PoolManager
**Файл:** `src/VolatilityGuardHookV5.sol:40-42`

```solidity
constructor(IPoolManager _poolManager) {
    poolManager = _poolManager;
    // ❌ Нет: require(_poolManager != address(0))
}
```

---

### 9. Неиспользуемый параметр sqrtPriceX96
**Файл:** `src/VolatilityGuardHookV5.sol:84`

```solidity
function afterInitialize(
    address,
    PoolKey calldata key,
    uint160 sqrtPriceX96,  // ❌ Не используется
    int24 tick
)
```

**Риск:**
- Возможно, должна быть валидация sqrtPrice
- Или проверка соответствия sqrtPrice и tick

---

### 10. Отсутствие событий для мониторинга
**Файл:** `src/VolatilityGuardHookV5.sol`

**Проблема:**
- Есть события PanicActivated/PanicExpired
- НЕТ события для нормального режима (FeeApplied)

**Рекомендация:**
```solidity
event FeeApplied(PoolId indexed poolId, uint24 fee, int24 currentTick, bool isPanic);

function beforeSwap(...) {
    // ...
    emit FeeApplied(poolId, currentFee, currentTick, block.timestamp < state.panicExpiry);
    return _return(currentFee);
}
```

---

## 🔍 ПРОВЕРОЧНЫЙ ЧЕКЛИСТ ДЛЯ ДИАГНОСТИКИ

### Если транзакции не проходят, проверьте:

1. ✅ **Адрес хука валиден?**
   ```bash
   cast call $HOOK_ADDRESS "poolManager()(address)"
   # Должен вернуть: 0x000000000004444c5dc75cB358380D2e3dE08A90
   ```

2. ✅ **Пул инициализирован?**
   ```bash
   cast call $POOL_MANAGER "getSlot0(bytes32)(uint160,int24,uint24,uint8)" $(cast keccak $POOL_ID)
   # sqrtPriceX96 не должен быть 0
   ```

3. ✅ **Хук привязан к пулу?**
   ```solidity
   // В PoolKey должен быть правильный hooks адрес
   PoolKey.hooks == 0x<your_hook_address>
   ```

4. ✅ **Есть ликвидность?**
   ```bash
   cast call $POOL_MANAGER "getLiquidity(bytes32)(uint128)" $(cast keccak $POOL_ID)
   # Должно быть > 0
   ```

5. ✅ **Режим паники активен?**
   ```bash
   cast call $HOOK_ADDRESS "isPanicking(bytes32)(bool)" $POOL_ID
   # Если true → комиссия 1% может блокировать транзакции
   ```

6. ✅ **Текущий тик в разумных пределах?**
   ```bash
   # currentTick должен быть в диапазоне ликвидности
   # Если currentTick < tickLower или > tickUpper → нет ликвидности → revert
   ```

7. ✅ **Достаточно gas limit?**
   ```bash
   # beforeSwap + getSlot0 + логика паники ≈ 50-80k gas
   # Полный своп ≈ 150-200k gas
   ```

---

## 🛠️ ПЛАН ИСПРАВЛЕНИЙ

### Приоритет 1 (СРОЧНО):
1. Исправить комиссии: 1000 / 3000 вместо 3000 / 10000
2. Добавить проверку инициализации в beforeSwap
3. Добавить try/catch для getSlot0

### Приоритет 2 (ВАЖНО):
4. Защитить afterInitialize от повторного вызова
5. Увеличить TICK_THRESHOLD до 200
6. Добавить события FeeApplied

### Приоритет 3 (ЖЕЛАТЕЛЬНО):
7. Валидация poolManager в конструкторе
8. Использовать sqrtPriceX96 или удалить параметр
9. Добавить view-функции для диагностики
10. Улучшить логику паники (продление или TWAP)

---

## 📊 СРАВНЕНИЕ С V3

| Параметр | V5 | V3 | Лучше |
|----------|----|----|-------|
| MIN_FEE | 0.30% | 0.25% | V3 |
| PANIC_FEE | 1.00% | 0.30% | V3 |
| TICK_THRESHOLD | 60 (~0.6%) | 60/150 | V3 |
| Защита от flash-loan | ❌ | ✅ (block cache) | V3 |
| Проверка инициализации | ❌ | ✅ | V3 |
| Продление паники | ❌ | ✅ (с hard cap) | V3 |
| Directional fees | ❌ | ✅ | V3 |
| Try/catch errors | ❌ | ❌ | = |

**ВЫВОД:** V3 хук значительно надежнее и безопаснее. Рекомендуется мигрировать на V3 или портировать его улучшения в V5.

---

## 🎯 ДОПОЛНИТЕЛЬНЫЕ ТЕСТЫ

Создайте тестовый скрипт для проверки:

```solidity
// test/VolatilityV5DiagnosticTest.s.sol
contract DiagnosticTest {
    function testHookInitialization() {
        // 1. Deploy hook
        // 2. Verify address flags
        // 3. Initialize pool
        // 4. Verify state.initialized == true
        // 5. Verify referenceTick == currentTick
    }
    
    function testSwapBeforeInit() {
        // Должен revertнуть с "Pool not initialized"
    }
    
    function testPanicMode() {
        // 1. Init pool at tick 0
        // 2. Mock getSlot0 → return tick 100
        // 3. Swap должен вернуть PANIC_FEE
    }
    
    function testGetSlot0Error() {
        // 1. Mock getSlot0 → revert
        // 2. Swap должен fallback на MIN_FEE (после fix)
    }
}
```

---

## 📞 СЛЕДУЮЩИЕ ШАГИ

1. **Немедленно:** Проверьте текущий статус пула через cast/web3
2. **Срочно:** Исправьте комиссии и добавьте проверки инициализации
3. **Важно:** Напишите comprehensive тесты
4. **Долгосрочно:** Рассмотрите миграцию на V3 архитектуру

---

Автор анализа: GitHub Copilot  
Дата: 21 мая 2026
