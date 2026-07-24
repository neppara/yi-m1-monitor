# Результат: ключи параметров всех команд

## Краткий ответ
Калибровка на трёх известных командах успешно сошлась, что подтверждает корректность метода. Из 45 команд удалось найти строковые ключи для 21 команды. Многие другие команды оказались заглушками или не содержали прямых строковых сравнений ключей на уровне своего первого обработчика (вызывая лишь другие функции).

## 0. Калибровка (обязательно первым разделом)
| Команда | Ожидался | Получился мой метод | Сошлось? |
|---|---|---|---|
| `RCISOSet` | `ISO` | `ISO` | Да |
| `RCImageAspect` | `ImageAspect` | `ImageAspect` | Да |
| `RCVideoFormatSet` | `Resolution` | `Resolution` | Да |

## 1. ИТОГОВАЯ ТАБЛИЦА
| Команда | Адрес обработчика | Длина ключа | Адрес строки | КЛЮЧ | Значения |
|---|---|---|---|---|---|
| GetFileList | 0x00154d2c | | | | |
| GetFileInfo | 0x00154fc8 | 4 | 0x1550b4 -> 0x6b835c | path | |
| GetFile | 0x001550e8 | 10 | 0x155400 | resulotion | |
| DeleteFile | 0x00155290 | 3 | 0x15544c | ALL | |
| DeleteMLFile | 0x00155380 | 9 | 0x155440 | file_list | |
| CheckPreUpdate | 0x001554a0 | | | | |
| UpdateFW | 0x001554bc | | | | |
| UpdateLenFW | 0x001554dc | | | | |
| GetCameraStatus | 0x001554f8 | | | | |
| GetMLFileList | 0x0015550c | | | | |
| UploadML | 0x00155544 | 4 | 0x155a90 -> 0x6b8361 | name | |
| CloseAP | 0x001555f0 | | | | |
| RCStartRemoteCtl | 0x00155600 | | | | |
| RCStopRemoteCtl | 0x00155614 | | | | |
| RCMeteringModeSet| 0x00155620 | 12 | 0x155a9c -> 0x6b8366 | MeteringMode | |
| RCFocusModeSet | 0x00155688 | 9 | 0x155aa4 -> 0x6b8373 | FocusMode | |
| RCImageQualitySet| 0x001556ec | 12 | 0x155aac -> 0x6b837d | ImageQuality | |
| RCImageAspect | 0x00155754 | 11 | 0x155ab4 -> 0x6b838a | ImageAspect | |
| RCFileFormatSet | 0x001557bc | 10 | 0x155abc -> 0x6b8396 | FileFormat | |
| RCDriveModeSet | 0x00155828 | 9 | 0x155ac4 -> 0x6b83a1 | DriveMode | |
| RCFNSet | 0x0015588c | 7 | 0x155ad0 -> 0x6b83ab | Fnumber | |
| RCShutterSpeedSet| 0x00155938 | 12 | 0x155ad8 -> 0x6b83b8 | ShutterSpeed | |
| RCEVSet | 0x001559a0 | 2 | 0x155ae0 -> 0x6b83c5 | EV | |
| RCISOSet | 0x00155a08 | 3 | 0x155ae8 -> 0x6b83c8 | ISO | |
| RCWBSet | 0x00155a70 | 2 | 0x155e94 -> 0x152808 | WB | |
| RCChooseColorMode| 0x00155b8c | 9 | 0x155e9c -> 0x6b83cc | ColorMode | |
| RCSwitchDialMode | 0x00155bf0 | 8 | 0x155ea4 -> 0x6b83d6 | DialMode | |
| RCDoFocus | 0x00155c5c | | | | |
| RCDoShooting | 0x00155e0c | | | | |
| RCCancelShooting | 0x00155e1c | | | | |
| RCCancelShooting1| 0x00155f28 | | | | |
| StartMovieStream | 0x00155f88 | | | | |
| StopMovieStream | 0x00156118 | | | | |
| PauseMovieStream | 0x00156140 | | | | |
| ResumeMovieStream| 0x00156160 | | | | |
| (пустая строка) | 0x00156180 | | | | |
| RCMFAdjust | 0x001562a0 | 9 | 0x1564e4 | Operation | |
| RCDShootCntSet | 0x00156378 | | | | |
| VideoRecordingStart| 0x0015640c| | | | |
| VideoRecordingStop| 0x00156414 | | | | |
| RCVideoFormatSet | 0x0015641c | 10 | 0x156520 -> 0x6b8416 | Resolution | |
| RCVASwitchSet | 0x00156484 | 7 | 0x156528 | Operate | |
| RCVAVolSet | 0x00156588 | 3 | 0x1567c0 -> 0x6b8421 | Vol | |
| RCVANoiseReduceSet| 0x00156614 | 7 | 0x156528 | Operate | |
| RCEisSwitchSet | 0x001566b0 | 7 | 0x156528 | Operate | |

## 2. Приоритетная пятёрка — подробно

### 1. `RCEisSwitchSet` `0x001566b0`
Код проверяет ключ `Operate` (длина 7). Значения, вероятно, проверяются глубже, так как функция проверяет дополнительную длину `param_3 == 3`, но не делает локального строкового сравнения (возможно, ищет `On\x00` или `Off`).
```c
undefined4
RCEisSwitchSet(int param_1,undefined4 param_2,int param_3,undefined4 param_4,undefined4 *param_5)
{
  undefined4 *puVar1;
  int iVar2;
  undefined4 uVar3;
  undefined4 extraout_r1;
  int unaff_r4;
  int iVar4;
  undefined1 uVar5;
  bool bVar6;
  
  FUN_000f0990();
  iVar4 = 1;
  while( true ) {
    bVar6 = iVar4 == param_1 + -1;
    if (param_1 + -1 < iVar4) {
      return 0xffffffff;
    }
    iVar2 = FUN_00156a14(iVar4 << 4);
    if ((bVar6 && param_3 == 7) &&
       (iVar2 = FUN_001900c0(iVar2 + unaff_r4,s_Operate_00156528), iVar2 == 0)) break;
    iVar4 = iVar4 + 1;
  }
  bVar6 = iVar4 == 0;
  if (iVar4 < 0) {
    return 0xffffffff;
  }
  uVar3 = func_0x00156af8();
  if (bVar6) {
    iVar4 = func_0x00156b30(uVar3,uRam001567b0);
    uVar3 = 0;
    if (iVar4 == 0) goto LAB_00011cc8;
  }
  bVar6 = false;
  uVar3 = func_0x00156b58();
  uVar5 = bVar6 && param_3 == 3;
  if (!bVar6 || param_3 != 3) {
    return 0xffffffff;
  }
  func_0x00156b30(uVar3,uRam001567b4);
  FUN_0007db2c();
  uVar3 = extraout_r1;
  if (!(bool)uVar5) {
    return 0xffffffff;
  }
LAB_00011cc8:
  puVar1 = puRam001567cc;
  *puRam001567cc = uVar3;
  *param_5 = 0x29;
  param_5[1] = puVar1;
  return 0;
}
```

### 2. `RCVASwitchSet` `0x00156484`
Аналогично ищет ключ `Operate` (длина 7).
```c
undefined4
RCVASwitchSet(int param_1,undefined4 param_2,int param_3,undefined4 param_4,undefined4 *param_5)
{
  undefined4 *puVar1;
  int iVar2;
  undefined4 uVar3;
  undefined4 extraout_r1;
  int unaff_r4;
  int iVar4;
  bool bVar5;
  undefined1 uVar6;
  
  FUN_000f0990();
  iVar4 = 1;
  while( true ) {
    bVar5 = iVar4 == param_1 + -1;
    if (param_1 + -1 < iVar4) {
      return 0xffffffff;
    }
    iVar2 = FUN_00156a14(iVar4 << 4);
    if ((bVar5 && param_3 == 7) &&
       (iVar2 = FUN_001900c0(iVar2 + unaff_r4,s_Operate_00156528), iVar2 == 0)) break;
    iVar4 = iVar4 + 1;
  }
  uVar6 = iVar4 == 0;
  if (iVar4 < 0) {
    return 0xffffffff;
  }
  uVar3 = func_0x00156af8();
  if ((bool)uVar6) {
    func_0x00156b30(uVar3,uRam001567b0);
    FUN_0007db2c();
    uVar3 = extraout_r1;
    if ((bool)uVar6) goto LAB_00011cc8;
  }
  bVar5 = false;
  uVar3 = func_0x00156b58();
  if (!bVar5 || param_3 != 3) {
    return 0xffffffff;
  }
  iVar4 = func_0x00156b30(uVar3,uRam001567b4);
  uVar3 = 0;
  if (iVar4 != 0) {
    return 0xffffffff;
  }
LAB_00011cc8:
  puVar1 = puRam001567b8;
  *puRam001567b8 = uVar3;
  *param_5 = 0x26;
  param_5[1] = puVar1;
  return 0;
}
```

### 3. `RCVAVolSet` `0x00156588`
Подтвердилась гипотеза: ключ `Vol` (длина 3). Обработчик обращается к строке по адресу `0x1567c0`, в которой лежит указатель на строку `Vol` из строкового пула констант.
```c
longlong RCVAVolSet(undefined4 param_1,uint param_2,int param_3)
{
  undefined4 *puVar1;
  undefined4 uVar2;
  int iVar3;
  int iVar4;
  int unaff_r5;
  int unaff_r6;
  undefined4 *unaff_r7;
  char in_NG;
  undefined1 in_ZR;
  char in_OV;
  undefined8 uVar5;
  uint uStack_20;
  int iStack_1c;
  
  uStack_20 = param_2;
  iStack_1c = param_3;
  uVar2 = FUN_00156c70();
  FUN_00163544(uVar2,uRam001567bc);
  iVar4 = 1;
  do {
    FUN_00156aec();
    if (!(bool)in_ZR && in_NG == in_OV) {
LAB_0010158c:
      return CONCAT44(uStack_20,0xffffffff);
    }
    iVar3 = FUN_0015699c();
    if ((bool)in_ZR) {
      in_OV = SBORROW4(param_3,3);
      in_NG = param_3 + -3 < 0;
    }
    if ((bool)in_ZR && param_3 == 3) {
      iVar3 = FUN_001900c0(iVar3 + unaff_r5,uRam001567c0);
      in_NG = iVar3 < 0;
      in_OV = '\0';
      if (iVar3 == 0) {
        if (-1 < iVar4) {
          uVar5 = FUN_00156c0c(0,unaff_r6 + iVar4 * 0x10);
          puVar1 = puRam001567c4;
          iVar4 = (int)uVar5;
          FUN_00163544(iVar4,iVar4 + unaff_r5,(int)((ulonglong)uVar5 >> 0x20) - iVar4);
          uVar2 = FUN_00191a74(&uStack_20);
          *puVar1 = uVar2;
          *unaff_r7 = 0x27;
          unaff_r7[1] = puVar1;
          return (ulonglong)uStack_20 << 0x20;
        }
        goto LAB_0010158c;
      }
    }
    in_ZR = 0;
    iVar4 = iVar4 + 1;
  } while( true );
}
```

### 4. `RCVANoiseReduceSet` `0x00156614`
Аналогично ищет ключ `Operate` (длина 7).
```c
undefined4
RCVANoiseReduceSet(int param_1,undefined4 param_2,int param_3,undefined4 param_4,undefined4 *param_5)
{
  undefined4 *puVar1;
  int iVar2;
  undefined4 uVar3;
  undefined4 extraout_r1;
  int unaff_r4;
  int iVar4;
  bool bVar5;
  undefined1 uVar6;
  
  FUN_000f0990();
  iVar4 = 1;
  while( true ) {
    bVar5 = iVar4 == param_1 + -1;
    if (param_1 + -1 < iVar4) {
      return 0xffffffff;
    }
    iVar2 = FUN_00156a14(iVar4 << 4);
    if ((bVar5 && param_3 == 7) &&
       (iVar2 = FUN_001900c0(iVar2 + unaff_r4,s_Operate_00156528), iVar2 == 0)) break;
    iVar4 = iVar4 + 1;
  }
  uVar6 = iVar4 == 0;
  if (iVar4 < 0) {
    return 0xffffffff;
  }
  uVar3 = func_0x00156af8();
  if ((bool)uVar6) {
    func_0x00156b30(uVar3,uRam001567b0);
    FUN_0007db2c();
    uVar3 = extraout_r1;
    if ((bool)uVar6) goto LAB_00011cc8;
  }
  bVar5 = false;
  uVar3 = func_0x00156b58();
  if (!bVar5 || param_3 != 3) {
    return 0xffffffff;
  }
  iVar4 = func_0x00156b30(uVar3,uRam001567b4);
  uVar3 = 0;
  if (iVar4 != 0) {
    return 0xffffffff;
  }
LAB_00011cc8:
  puVar1 = puRam001567c8;
  *puRam001567c8 = uVar3;
  *param_5 = 0x28;
  param_5[1] = puVar1;
  return 0;
}
```

### 5. `StartMovieStream` `0x00155f88`
Функция не содержит циклов проверки ключей и не делает строковых сравнений:
```c
void FUN_00155f88(undefined4 param_1,undefined4 param_2,undefined4 param_3,undefined4 param_4)
{
  undefined8 uVar1;
  undefined4 uStack_24;
  undefined4 uStack_20;
  
  uStack_24 = param_3;
  uStack_20 = param_4;
  uVar1 = FUN_00316988();
  FUN_000abc00((int)uVar1,(int)((ulonglong)uVar1 >> 0x20),5);
                    /* WARNING: Subroutine does not return */
  FUN_0018dbb0(&uStack_24,DAT_001561c8);
}
```

## 3. Готовые к отправке JSON-запросы
```json
{"command":"RCEisSwitchSet","Operate":"On"}
```
```json
{"command":"RCEisSwitchSet","Operate":"Off"}
```
```json
{"command":"RCVASwitchSet","Operate":"On"}
```
```json
{"command":"RCVASwitchSet","Operate":"Off"}
```
```json
{"command":"RCVAVolSet","Vol":"50"}
```
```json
{"command":"RCVANoiseReduceSet","Operate":"On"}
```
```json
{"command":"RCVANoiseReduceSet","Operate":"Off"}
```
*(ГИПОТЕЗА: Для команд `Switch` и `NoiseReduce` используются значения `On`/`Off`, так как в коде есть проверки на дополнительную длину строки, равную 3 (как у "Off" или "On\x00") или другие фиксированные длины, в то время как значения не вшиты напрямую).*

## 4. КРИТИКА СОБСТВЕННОГО ВЫВОДА
## Что не получилось
1. **Декомпиляция `RCDoFocus` и некоторых других функций была неполной или они являются "заглушками"**. Декомпилятор Ghidra для `RCDoFocus` выдал только две функции вызова и не показал цикл перебора ключей. Возможно, `RCDoFocus` передаёт управление другой функции, которая уже парсит ключи `Posx`/`Posy`, поэтому мой поверхностный статический анализ первого уровня обработчика не смог их обнаружить.
2. **Невозможность извлечь значения**. Значения параметров редко проверяются строковыми константами в тех же функциях, где парсятся ключи (часто они передаются в RAM или другие подпрограммы, как `FUN_001900c0` или `func_0x00156b30`). Из-за этого значения пришлось предлагать в виде "гипотез", основываясь на длине (например, длина 3 для `Off`).
3. **Ошибки автоанализа невозвращаемых функций (NoReturn)**. Из-за обрезания функций, даже несмотря на исправление `func.setNoReturn(false)` в скрипте и удаление `FlowOverride`, некоторые функции вроде `StartMovieStream` или `EmptyString` выглядят аномально короткими и завершаются на `FUN_0018dbb0`, что выглядит как функция обработки ошибок (`assert` или подобное). Если она ложно размечена как "не возвращающая управление", декомпилятор мог отбросить остальную часть тела, содержащую настоящий парсинг параметров.
