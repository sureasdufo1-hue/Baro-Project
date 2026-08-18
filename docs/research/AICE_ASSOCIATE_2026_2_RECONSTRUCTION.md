# AICE Associate 최근 5회차 기출·복원문제 자료집

## 제2차분 — 2026년 제2회 조사 및 복원 가능한 문제 골격

조사 기준일: 2026년 8월 18일

## 1. 결론

2026년 제2회 Associate 시험은 공식 일정상 4월 24~25일 시행되었다. 공개된 합격후기는 여러 건 확인되지만, 데이터명·함수·모델·파라미터·정답 수치까지 기록한 문제별 복원자료는 확인하지 못했다.

따라서 이번 차분의 판정은 다음과 같다.

> **[출제 흐름 복원 가능 / 정확한 문항 원문과 함수 단위 복원 불가]**

확인되지 않은 내용을 실제 기출로 표시하거나 14문항에 맞추지 않는다.

## 2. 출처별 확인사항

| 출처 | 등급 | 확인 가능한 내용 | 확인할 수 없는 내용 |
| --- | --- | --- | --- |
| AICE 공식 일정 | A | 4월 24~25일, 11시·16시 세션, 90분 | 세션별 문제 내용 |
| AICE 공식 Associate 안내 | A | 분석·전처리·모델링 범위와 배점 | 특정 회차 문제 |
| 2026-05-12 전공자 후기 | C | 실전 모의고사 유형과 유사, 알 수 없는 13점 감점 | 정확한 문항·감점 위치 |
| 2026-05-12 비전공자 후기 | C | 초반부는 수월, 마지막 딥러닝에 생소한 유형 | 딥러닝 모델·Layer·인자 |
| 2026-05-13 비전공자 후기 | C | 딥러닝보다 나머지 파트 득점 전략 | 실제 출제 코드 |
| 교육기관 4월 시험 총평 안내 | C | 4월 시험 기반 유형 분석이 별도로 존재 | 공개 페이지에는 상세 유형 없음 |

같은 교육기관 게시판에 실린 후기는 작성자가 다르더라도 학습자료와 표현이 유사할 수 있으므로 완전히 독립적인 문제복원 자료로 과대평가하지 않는다.

## 3. 비교적 신뢰할 수 있는 시험 흐름

복수 후기에서 다음 흐름은 서로 모순되지 않는다.

1. 공식 샘플과 모의고사로 대비 가능한 정형 데이터 문제였다.
2. 초반 데이터 분석·전처리 문제는 반복 연습자에게 비교적 익숙했다.
3. 후반 모델링, 특히 마지막 딥러닝 부분에서 생소함 또는 감점이 발생했다.
4. 문제를 이해하고 모두 작성했다고 느껴도 채점 기준을 정확히 알기 어려웠다.

단, 위 내용만으로 특정 함수가 실제 출제되었다고 단정할 수 없다.

## 4. 복원 골격 01 — 정형 데이터 분석·전처리 흐름

### [기출복원 재구성]

- 복원 신뢰도: 낮음
- 확인 근거: 초반부가 수월했다는 후기, 모의고사 유형과 유사했다는 복수 후기, 공식 출제범위
- 확인되지 않은 요소: 데이터셋, 컬럼, 결측치 처리법, 인코더, 스케일러, 분할 비율

주어진 정형 데이터를 확인하고 모델 입력에 사용할 수 있도록 전처리한다.

```python
# 실제 2026년 2회 원문 코드가 아닌 안전한 연습 골격
df.shape
df.info()
df.describe(include="all")

# 문제 지시에 따라 결측치·이상치·범주형 변수를 처리한다.
# 처리 방법과 기준값은 원문이 확인되지 않았으므로 임의 확정하지 않는다.
```

### 확인 포인트

- `shape`, `info`, `describe`가 2회에 실제 출제됐다는 직접 증거는 없다.
- 공식 분석 범위에 해당하고 초반부 정형 유형 복원용으로만 제시한다.
- 결측치를 평균이나 중앙값으로 처리했다고 단정하지 않는다.

## 5. 복원 골격 02 — Train/Test와 머신러닝 모델링

### [기출복원 재구성]

- 복원 신뢰도: 낮음
- 확인 근거: 모의고사와 실제 시험 유형이 유사하다는 복수 후기, 공식 모델링 범위
- 확인되지 않은 요소: 분류/회귀 여부, 모델명, 평가지표, random state

```python
from sklearn.model_selection import train_test_split

X = df.drop(columns=["target"])
y = df["target"]

X_train, X_test, y_train, y_test = train_test_split(
    X,
    y,
    test_size=<지정값>,
    random_state=<지정값>,
)

model = <문제에서 지정한 모델>(...)
model.fit(X_train, y_train)
y_pred = model.predict(X_test)
```

`target`, 분할 비율과 모델은 연습용 자리표시자다. 제2회 원문 값이 아니다.

## 6. 복원 골격 03 — 마지막 딥러닝 문제

### [기출복원 재구성]

- 복원 신뢰도: 중간 이하
- 확인 근거: 비전공자 후기에 “마지막 딥러닝 파트에서 생소한 유형”이라는 구체적 위치·영역 기록
- 확인되지 않은 요소: TensorFlow/Keras 세부 API, Layer 수, activation, loss, optimizer, callback

후기에서 직접 확인되는 것은 마지막 부분이 딥러닝이었고 일부 응시자에게 생소했다는 사실뿐이다. 다음은 실행 구조를 익히기 위한 골격이며 실제 기출 문장이 아니다.

```python
model = <문제에서 요구한 신경망 모델>
model.compile(
    optimizer=<지정 optimizer>,
    loss=<지정 loss>,
    metrics=<지정 metrics>,
)

history = model.fit(
    X_train,
    y_train,
    validation_data=(X_test, y_test),
    epochs=<지정값>,
    callbacks=<지정 callback>,
)
```

### 복원 한계

`Dense`, `EarlyStopping`, `ModelCheckpoint`, 특정 activation이 제2회에 출제됐다고 단정할 근거는 현재 없다. 이 함수들은 다른 회차 복원 또는 공식 범위 기반 예상문제에서만 별도 표시해야 한다.

## 7. 기출유형 예상문제

아래 문제는 제2회 기출이 아니다. 공식 출제범위와 후기의 취약영역을 바탕으로 만든 보충문제다.

### 예상문제 01 — 분류와 회귀 출력층 구분

#### [기출유형 예상문제]

이진 분류에서 출력층을 구성하는 대표적인 방법 두 가지를 작성하시오.

```python
# 방법 1
Dense(1, activation="sigmoid")

# 방법 2
Dense(2, activation="softmax")
```

라벨 형태와 loss 함수가 출력층 구성과 호환되어야 한다. 제2회가 어느 구성을 사용했는지는 확인되지 않았다.

### 예상문제 02 — 학습과 평가 데이터 분리

#### [기출유형 예상문제]

다음 코드의 문제점을 설명하시오.

```python
model.fit(X_test, y_test)
y_pred = model.predict(X_test)
```

정답: 평가 데이터를 학습에 사용해 일반화 성능을 독립적으로 측정할 수 없다. 일반적인 구조는 `X_train`, `y_train`으로 학습하고 `X_test`로 예측하는 것이다.

### 예상문제 03 — Callback 역할 구분

#### [기출유형 예상문제]

```python
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint
```

- `EarlyStopping`: 지정 지표 개선이 멈추면 학습 종료
- `ModelCheckpoint`: 조건에 따라 모델 또는 weight 저장

이는 후기에서 확인된 제2회 실제 함수 목록이 아니라, 마지막 딥러닝 취약영역을 보완하기 위한 예상문제다.

## 8. 이번 차분에서 복원하지 않은 항목

다음은 정확한 출제 근거가 없어 제2회 기출로 작성하지 않는다.

- 데이터셋과 목표변수 이름
- 분류 또는 회귀 세션 구분
- 결측치·이상치 기준
- Scaling·Encoding 함수
- 머신러닝 모델명과 파라미터
- 평가지표와 요구 소수점 자리
- 딥러닝 Layer 수와 node 수
- activation, loss, optimizer
- callback 구성
- 최종 예측값

## 9. 신뢰도 통계

| 분류 | 확보 수 |
| --- | ---: |
| 공식 제2회 전체 원문 | 0 |
| 정확한 문장 복원 | 0 |
| 구체적 함수 단위 복원 | 0 |
| 출제 흐름 복원 골격 | 3 |
| 별도 예상문제 | 3 |

## 10. 제2차분 핵심 결론

2026년 제2회는 모의고사·공식 샘플과 유사한 정형 흐름이었다는 복수 후기가 있으나, 공개 자료만으로 실제 14문항을 복원할 수는 없다. 가장 구체적인 단서는 후반의 마지막 딥러닝 영역에서 생소한 유형과 실수가 있었다는 기록이다.

따라서 현재 단계의 최선은 다음과 같다.

1. 제2회를 실제 함수 목록으로 과장하지 않는다.
2. 데이터 분석 → 전처리 → 모델링 → 딥러닝의 흐름만 낮은 신뢰도로 복원한다.
3. 구체적 함수 연습은 `[기출유형 예상문제]`로 분리한다.
4. 향후 더 구체적인 독립 응시기록이 발견될 때만 복원 등급을 올린다.

다음 제3차분은 2026년 제1회 후기를 개별 조사하되, 제2회와 동일한 교육자료를 사용했다는 이유만으로 같은 문제가 출제됐다고 추정하지 않는다.

## 출처

- [AICE 공식 시험 일정](https://aice.study/certi/examSchedule)
- [AICE 공식 Associate 출제범위](https://aice.study/info/aice/asso)
- [2026년 2회 AICE Associate 합격수기 — 모델링 27점 사례](https://www.epasskorea.com/Customer/board_after_best.asp?Cate_IDX=&LEC_IDX=&TEA_IDX=&bcs_idx=&bg_idx=18&bmode=detail&intB_idx=12430&intBc_idx=37&link_idx=10786&page=1&pageb=&searchoption=&searchstring=)
- [2026년 2회 AICE Associate 합격수기 — 모의고사 유형 유사](https://www.epasskorea.com/Customer/board_after_best.asp?Cate_IDX=&LEC_IDX=&TEA_IDX=&bcs_idx=&bg_idx=18&bmode=detail&intB_IDX=12431&intBc_idx=37&link_idx=10786&page=1&pageb=&searchoption=&searchstring=)
- [2026년 2회 AICE Associate 합격수기 — 마지막 딥러닝 생소 유형](https://www.epasskorea.com/Customer/board_after_best.asp?Cate_IDX=&LEC_IDX=&TEA_IDX=&bcs_idx=&bg_idx=18&bmode=detail&intB_IDX=12432&intBc_idx=37&link_idx=10786&page=1&pageb=&searchoption=&searchstring=)
- [2026 AICE Associate 2회 합격수기 — 딥러닝 외 영역 득점 전략](https://epasskorea.com/Customer/board_after_best.asp?Cate_IDX=132722&LEC_IDX=&TEA_IDX=&bcs_idx=&bg_idx=18&bmode=detail&intB_idx=12436&intBc_idx=37&link_idx=5203&page=1&pageb=&searchoption=&searchstring=)
- [2026년 4월 시험 기반 출제경향 안내](https://www1.epasskorea.com/Board/curriculum_notice.asp?Cate_IDX=132722&LEC_IDX=&TEA_IDX=&bcs_idx=&bg_idx=28&bmode=detail&intB_idx=13157&intBc_idx=106&link_idx=13971&nCate_IDX=13272202&page=1&searchoption=&searchstring=&type=C)
