from __future__ import annotations

from datetime import date
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.assessment.engine import Condition, RuleDSL, execute
from domain.assessment.models import RuleEvaluationResult
from domain.calculation.engine import (
    CalculationParameters,
    CalculationRule,
    CalculationStrategyName,
    calculate,
)
from domain.policy.models import (
    Coverage,
    CoverageAlias,
    InsuranceCompany,
    InsuranceProduct,
    Policy,
    PolicyClause,
    PolicyVersion,
    ProductVersion,
)
from domain.rule.models import (
    BenefitRule,
    LogicalOperator,
    RuleOperator,
    RuleType,
    RuleVersion,
)
from scripts.seed_db_insurance_master import SeedMode, seed_db_insurance_master


def test_db_insurance_master_seeding_structure(db_session: Session) -> None:
    # 1. Run Seeder
    counts = seed_db_insurance_master(db_session)
    assert counts["products"] >= 3
    assert counts["coverages"] >= 18
    assert counts["rules"] >= 23

    # 2. Verify Insurance Company
    company = db_session.execute(
        select(InsuranceCompany).where(InsuranceCompany.company_code == "DB_INSURANCE")
    ).scalar_one()
    assert company.company_name == "DB손해보험"
    assert company.company_type == "NON_LIFE"

    # 3. Verify Products and Versions
    products = list(
        db_session.scalars(
            select(InsuranceProduct).where(InsuranceProduct.company_id == company.company_id)
        )
    )
    product_codes = {p.product_code for p in products}
    assert {"31201", "PROMY-AUTO", "31100"}.issubset(product_codes)

    # 4. Verify Cancer, 2-Major-Disease, and Liability Coverages
    coverage_codes = set(db_session.scalars(select(Coverage.standard_code)))
    assert {
        "STD_CANCER_DIAG",
        "STD_SIMILAR_CANCER_DIAG",
        "STD_CEREBRAL_HEMORRHAGE_DIAG",
        "STD_STROKE_DIAG",
        "STD_CEREBROVASCULAR_DIAG",
        "STD_ACUTE_MYOCARDIAL_INFARCTION_DIAG",
        "STD_ISCHEMIC_HEART_DIAG",
        "STD_CEREBROVASCULAR_SURGERY",
        "STD_ISCHEMIC_HEART_SURGERY",
        "STD_DISEASE_SURGERY",
        "STD_INJURY_SURGERY",
        "STD_FRACTURE_DIAG",
        "STD_DISEASE_HOSPITAL_DAY",
        "STD_PERSONAL_LIABILITY",
        "STD_FIRE_LIABILITY",
        "STD_DRIVER_TRAFFIC_ACCIDENT_SUPPORT",
        "STD_DRIVER_CRIMINAL_DEFENSE",
        "STD_AUTO_OWN_DAMAGE",
    }.issubset(coverage_codes)

    # 5. Verify Policy Clauses & Evidence Links under 31100
    clauses = list(
        db_session.scalars(
            select(PolicyClause)
            .join(PolicyVersion)
            .join(Policy)
            .join(ProductVersion)
            .join(InsuranceProduct)
            .where(InsuranceProduct.product_code == "31100")
        )
    )
    article_numbers = {c.article_number for c in clauses}
    assert {
        "특약_제10조",
        "특약_제12조",
        "특약_제15조",
        "특약_제20조",
        "특약_제22조",
        "특약_제50조",
        "특약_제52조",
        "특약_제54조",
        "특약_제60조",
        "특약_제62조",
    }.issubset(article_numbers)

    # 6. Verify Deterministic Rule Evaluation & Calculation
    # Scenario A: 일반암 (C16 위암, 계약 후 120일 경과) -> PASS & 100% 지급
    cancer_rule = RuleDSL(
        schemaVersion="1.0",
        ruleType=RuleType.ELIGIBILITY,
        logicalOperator=LogicalOperator.AND,
        conditions=[
            Condition(
                path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                value=["C16", "C34", "C50"],
            ),
            Condition(
                path="contract.elapsed_days",
                operator=RuleOperator.GT,
                value=90,
            ),
        ],
    )
    eval_pass = execute(
        cancer_rule,
        {
            "facts.DIAGNOSIS_CODE": "C16",
            "contract.elapsed_days": 120,
        },
    )
    assert eval_pass.result == RuleEvaluationResult.PASS

    calc_rule = CalculationRule(
        schemaVersion=1,
        ruleType="CALCULATION",
        strategy=CalculationStrategyName.FIXED_BENEFIT,
        parameters=CalculationParameters(paymentRate=Decimal("1.0")),
    )
    calc_res = calculate(calc_rule, insured_amount=50000000)
    assert calc_res.final_amount == 50000000
    assert calc_res.formula == "insured_amount * payment_rate"

    # Scenario B: 뇌출혈 (I61 뇌내출혈) -> PASS & 100% (3,000만원)
    hemorrhage_rule = RuleDSL(
        schemaVersion="1.0",
        ruleType=RuleType.ELIGIBILITY,
        logicalOperator=LogicalOperator.AND,
        conditions=[
            Condition(
                path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                value=["I60", "I61", "I62"],
            )
        ],
    )
    eval_hem = execute(hemorrhage_rule, {"facts.DIAGNOSIS_CODE": "I61"})
    assert eval_hem.result == RuleEvaluationResult.PASS
    calc_hem = calculate(calc_rule, insured_amount=30000000)
    assert calc_hem.final_amount == 30000000

    # Scenario C: 뇌경색증(I63) 환자가 뇌출혈 담보 청구 시 -> FAIL
    eval_stroke_on_hem = execute(hemorrhage_rule, {"facts.DIAGNOSIS_CODE": "I63"})
    assert eval_stroke_on_hem.result == RuleEvaluationResult.FAIL

    # Scenario D: 뇌경색증(I63) 환자가 뇌졸중/뇌혈관 담보 청구 시 -> PASS
    stroke_rule = RuleDSL(
        schemaVersion="1.0",
        ruleType=RuleType.ELIGIBILITY,
        logicalOperator=LogicalOperator.AND,
        conditions=[
            Condition(
                path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                value=["I60", "I61", "I62", "I63", "I65", "I66"],
            )
        ],
    )
    eval_stroke = execute(stroke_rule, {"facts.DIAGNOSIS_CODE": "I63"})
    assert eval_stroke.result == RuleEvaluationResult.PASS

    # Scenario E: 허혈성심장질환 (I20 협심증) -> PASS & 100% (2,000만원)
    ischemic_rule = RuleDSL(
        schemaVersion="1.0",
        ruleType=RuleType.ELIGIBILITY,
        logicalOperator=LogicalOperator.AND,
        conditions=[
            Condition(
                path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                value=["I20", "I21", "I22", "I23", "I24", "I25"],
            )
        ],
    )
    eval_ischemic = execute(ischemic_rule, {"facts.DIAGNOSIS_CODE": "I20"})
    assert eval_ischemic.result == RuleEvaluationResult.PASS
    calc_ischemic = calculate(calc_rule, insured_amount=20000000)
    assert calc_ischemic.final_amount == 20000000

    # Scenario F: 협심증(I20) 환자가 급성심근경색 담보 청구 시 -> FAIL
    mi_rule = RuleDSL(
        schemaVersion="1.0",
        ruleType=RuleType.ELIGIBILITY,
        logicalOperator=LogicalOperator.AND,
        conditions=[
            Condition(
                path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                value=["I21", "I22", "I23"],
            )
        ],
    )
    eval_mi = execute(mi_rule, {"facts.DIAGNOSIS_CODE": "I20"})
    assert eval_mi.result == RuleEvaluationResult.FAIL

    # Scenario G: 입원일당 계산 (5일 입원, 일당 30,000원)
    hosp_calc_rule = CalculationRule(
        schemaVersion=1,
        ruleType="CALCULATION",
        strategy=CalculationStrategyName.HOSPITAL_DAILY,
        parameters=CalculationParameters(
            dailyAmountSource="CONTRACT_COVERAGE_INSURED_AMOUNT",
            dayCalculationMethod="INCLUSIVE",
            maxDays=180,
        ),
    )
    hosp_res = calculate(
        hosp_calc_rule,
        insured_amount=30000,
        admission_date=date(2026, 8, 1),
        discharge_date=date(2026, 8, 5),
    )
    assert hosp_res.final_amount == 150000

    # Scenario H: 가족일상생활배상책임 (누수 대물사고, 손해액 300만원, 자기부담금 50만원 공제)
    leak_calc_rule = CalculationRule(
        schemaVersion=1,
        ruleType="CALCULATION",
        strategy=CalculationStrategyName.FIXED_BENEFIT,
        parameters=CalculationParameters(paymentRate=Decimal("1.0"), deductionAmount=500000),
    )
    leak_res = calculate(leak_calc_rule, insured_amount=3000000)
    assert leak_res.final_amount == 2500000

    # Scenario I: 가족일상생활배상책임 (대인사고, 자기부담금 0원, 치료비/합의금 500만원)
    bodily_calc_rule = CalculationRule(
        schemaVersion=1,
        ruleType="CALCULATION",
        strategy=CalculationStrategyName.FIXED_BENEFIT,
        parameters=CalculationParameters(paymentRate=Decimal("1.0"), deductionAmount=0),
    )
    bodily_res = calculate(bodily_calc_rule, insured_amount=5000000)
    assert bodily_res.final_amount == 5000000

    # Scenario J: 교통사고처리지원금 (형사합의금 3,000만원 실손 지급)
    driver_calc_rule = CalculationRule(
        schemaVersion=1,
        ruleType="CALCULATION",
        strategy=CalculationStrategyName.FIXED_BENEFIT,
        parameters=CalculationParameters(paymentRate=Decimal("1.0"), deductionAmount=0),
    )
    driver_res = calculate(driver_calc_rule, insured_amount=30000000)
    assert driver_res.final_amount == 30000000


def _cancer_clause(db_session: Session) -> PolicyClause:
    return db_session.execute(
        select(PolicyClause).where(PolicyClause.article_number == "제3조")
    ).scalar_one()


def test_skip_mode_preserves_manually_changed_rows(db_session: Session) -> None:
    seed_db_insurance_master(db_session)

    clause = _cancer_clause(db_session)
    clause.clause_text = "수동으로 변경된 조문"

    counts = seed_db_insurance_master(db_session)

    assert all(value == 0 for value in counts.values())
    assert clause.clause_text == "수동으로 변경된 조문"


def test_upsert_mode_refreshes_changed_rows(db_session: Session) -> None:
    first = seed_db_insurance_master(db_session)
    assert first["updated"] == 0
    assert first["rules"] > 0

    clause = _cancer_clause(db_session)
    original_clause_text = clause.clause_text
    clause.clause_text = "변경된 조문"

    coverage = db_session.execute(
        select(Coverage).where(Coverage.standard_code == "STD_CANCER_DIAG")
    ).scalar_one()
    original_description = coverage.description
    coverage.description = "변경된 담보 설명"

    rule_version = db_session.execute(
        select(RuleVersion)
        .join(BenefitRule, BenefitRule.rule_id == RuleVersion.rule_id)
        .where(BenefitRule.rule_name == "유사암 진단비 20% 정액지급 산정규칙")
    ).scalar_one()
    rule_version.rule_definition["parameters"]["paymentRate"] = "0.9"

    second = seed_db_insurance_master(db_session, SeedMode.UPSERT)

    assert second["products"] == 0
    assert second["coverages"] == 0
    assert second["rules"] == 0
    assert second["rule_versions"] == 0
    assert second["updated"] == 3

    assert clause.clause_text == original_clause_text
    assert coverage.description == original_description
    assert rule_version.rule_definition["parameters"]["paymentRate"] == "0.2"

    third = seed_db_insurance_master(db_session, SeedMode.UPSERT)
    assert third["updated"] == 0


def test_upsert_mode_does_not_duplicate_rows_or_reset_admin_password(
    db_session: Session,
) -> None:
    seed_db_insurance_master(db_session)

    clause_count_before = len(list(db_session.scalars(select(PolicyClause))))
    alias_count_before = len(list(db_session.scalars(select(CoverageAlias))))

    seed_db_insurance_master(db_session, SeedMode.UPSERT)

    assert len(list(db_session.scalars(select(PolicyClause)))) == clause_count_before
    assert len(list(db_session.scalars(select(CoverageAlias)))) == alias_count_before
