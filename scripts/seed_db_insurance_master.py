from __future__ import annotations

# ruff: noqa: E402
import sys
import uuid
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sqlalchemy import select
from sqlalchemy.orm import Session

from domain.policy.models import (
    Coverage,
    CoverageAlias,
    InsuranceCompany,
    InsuranceProduct,
    InsuranceType,
    MasterStatus,
    Policy,
    PolicyClause,
    PolicyType,
    PolicyVersion,
    PolicyVersionStatus,
    ProductVersion,
    VersionStatus,
)
from domain.rule.models import (
    BenefitRule,
    BenefitRuleClause,
    LogicalOperator,
    RuleCondition,
    RuleOperator,
    RuleSourceType,
    RuleStatus,
    RuleType,
    RuleVersion,
)
from domain.user.models import User, UserRole, UserStatus
from infrastructure.database.session import SessionLocal
from shared.security.passwords import hash_password


def seed_db_insurance_master(db: Session) -> dict[str, int]:
    """Seed comprehensive DB Insurance product, policy, coverage, and rule masters."""
    # 1. System Admin User for audits/approvals
    admin = db.execute(
        select(User).where(User.email == "admin@claimlens.system")
    ).scalar_one_or_none()
    if not admin:
        admin = User(
            user_id=uuid.uuid4(),
            email="admin@claimlens.system",
            password_hash=hash_password("DevAdminSecret2026!"),
            display_name="DB Insurance Master Admin",
            role=UserRole.SYSTEM_ADMIN,
            status=UserStatus.ACTIVE,
        )
        db.add(admin)
        db.flush()

    # 2. Insurance Company: DB손해보험
    company = db.execute(
        select(InsuranceCompany).where(InsuranceCompany.company_code == "DB_INSURANCE")
    ).scalar_one_or_none()
    if not company:
        company = InsuranceCompany(
            company_id=uuid.uuid4(),
            company_code="DB_INSURANCE",
            company_name="DB손해보험",
            company_type="NON_LIFE",
            status=MasterStatus.ACTIVE,
        )
        db.add(company)
        db.flush()

    counts = {
        "products": 0,
        "product_versions": 0,
        "policies": 0,
        "policy_versions": 0,
        "clauses": 0,
        "coverages": 0,
        "aliases": 0,
        "rules": 0,
        "rule_versions": 0,
        "conditions": 0,
    }

    # -------------------------------------------------------------
    # 3. Standard Coverages
    # -------------------------------------------------------------
    standard_coverages_def = [
        # 암/질병
        {
            "standard_code": "STD_CANCER_DIAG",
            "coverage_name": "일반암진단비(유사암제외)",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "약관에서 정한 암(유사암 제외)으로 최초 진단확정 시 가입금액 지급",
            "aliases": ["일반암진단비", "암진단비(유사암제외)", "암진단비", "암진단금"],
        },
        {
            "standard_code": "STD_SIMILAR_CANCER_DIAG",
            "coverage_name": "유사암진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "기타피부암, 갑상선암, 제자리암, 경계성종양 진단확정 시 20% 지급",
            "aliases": ["유사암진단비", "소액암진단비", "유사암진단금", "갑상선암진단비"],
        },
        {
            "standard_code": "STD_CANCER_TREATMENT",
            "coverage_name": "암주요치료비(연간1회한)",
            "coverage_category": "TREATMENT",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "암 진단확정 후 암수술, 항암방사선, 항암약물치료 시 연간 1회 지급",
            "aliases": ["암주요치료비", "암치료비지원", "암주요치료비Ⅱ(유사암제외)"],
        },
        # 뇌혈관 질환군
        {
            "standard_code": "STD_CEREBRAL_HEMORRHAGE_DIAG",
            "coverage_name": "뇌출혈진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "약관에서 정한 뇌출혈(I60~I62)로 진단확정 시 가입금액 100% 지급",
            "aliases": ["뇌출혈진단비", "뇌출혈진단금", "뇌출혈"],
        },
        {
            "standard_code": "STD_STROKE_DIAG",
            "coverage_name": "뇌졸중진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "약관에서 정한 뇌졸중(I60~I63, I65, I66)으로 진단확정 시 지급",
            "aliases": ["뇌졸중진단비", "뇌졸중진단금", "뇌경색진단비"],
        },
        {
            "standard_code": "STD_CEREBROVASCULAR_DIAG",
            "coverage_name": "뇌혈관질환진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "약관에서 정한 뇌혈관질환(I60~I69)으로 진단확정 시 지급",
            "aliases": ["뇌혈관질환진단비", "뇌혈관진단비", "뇌혈관질환진단금"],
        },
        # 허혈성/심장 질환군
        {
            "standard_code": "STD_ACUTE_MYOCARDIAL_INFARCTION_DIAG",
            "coverage_name": "급성심근경색증진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "약관에서 정한 급성심근경색증(I21~I23)으로 진단확정 시 100% 지급",
            "aliases": ["급성심근경색증진단비", "급성심근경색진단비", "심근경색진단비"],
        },
        {
            "standard_code": "STD_ISCHEMIC_HEART_DIAG",
            "coverage_name": "허혈성심장질환진단비",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "협심증(I20) 및 급성심근경색 등 허혈성심장질환(I20~I25) 진단 시 지급",
            "aliases": ["허혈성심장질환진단비", "허혈성심장진단비", "협심증진단비"],
        },
        # 수술/상해/골절/입원
        {
            "standard_code": "STD_CEREBROVASCULAR_SURGERY",
            "coverage_name": "뇌혈관질환수술비",
            "coverage_category": "SURGERY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "뇌혈관질환(I60~I69)으로 인하여 수술을 받은 경우 1회당 지급",
            "aliases": ["뇌혈관질환수술비", "뇌혈관수술비", "뇌수술비"],
        },
        {
            "standard_code": "STD_ISCHEMIC_HEART_SURGERY",
            "coverage_name": "허혈성심장질환수술비",
            "coverage_category": "SURGERY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "허혈성심장질환(I20~I25)으로 인하여 수술을 받은 경우 1회당 지급",
            "aliases": ["허혈성심장질환수술비", "허혈심장수술비", "스텐트삽입수술비"],
        },
        {
            "standard_code": "STD_DISEASE_SURGERY",
            "coverage_name": "질병수술비",
            "coverage_category": "SURGERY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "질병으로 인하여 병원 또는 의원 등에서 수술을 받은 경우 1회당 지급",
            "aliases": ["질병수술비", "질병수술급여금", "질병수술"],
        },
        {
            "standard_code": "STD_INJURY_SURGERY",
            "coverage_name": "상해수술비",
            "coverage_category": "SURGERY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "외래 사고로 상해를 입고 수술을 받은 경우 1회당 지급",
            "aliases": ["상해수술비", "상해수술급여금", "상해수술"],
        },
        {
            "standard_code": "STD_FRACTURE_DIAG",
            "coverage_name": "골절진단비(치아파절제외)",
            "coverage_category": "DIAGNOSIS",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "상해로 인하여 골절 분류표(치아파절 제외)에 정한 골절 진단 시 지급",
            "aliases": ["골절진단비", "골절진단비(치아파절제외)", "골절진단금"],
        },
        {
            "standard_code": "STD_DISEASE_HOSPITAL_DAY",
            "coverage_name": "질병입원일당(1-180일)",
            "coverage_category": "HOSPITALIZATION",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "질병 입원 치료 시 입원 1일당 가입금액 지급 (180일 한도)",
            "aliases": ["질병입원일당", "질병입원비", "질병입원일당(1일이상180일한도)"],
        },
        # 배상책임 및 법률비용 특약군
        {
            "standard_code": "STD_PERSONAL_LIABILITY",
            "coverage_name": "가족일상생활배상책임(대인/대물)",
            "coverage_category": "LIABILITY",
            "insurance_type": InsuranceType.LIABILITY,
            "description": "일상생활 중 타인의 신체나 재물 손해로 인한 법률상 배상책임 보상",
            "aliases": [
                "가족일상생활배상책임",
                "일상생활배상책임",
                "일배책",
                "가족일상생활중배상책임",
            ],
        },
        {
            "standard_code": "STD_FIRE_LIABILITY",
            "coverage_name": "화재(주택)배상책임",
            "coverage_category": "LIABILITY",
            "insurance_type": InsuranceType.LIABILITY,
            "description": "주택 화재로 타인의 재물 또는 신체에 손해를 입힌 경우 보상",
            "aliases": ["화재배상책임", "주택화재배상책임", "화재대물배상"],
        },
        {
            "standard_code": "STD_DRIVER_TRAFFIC_ACCIDENT_SUPPORT",
            "coverage_name": "교통사고처리지원금",
            "coverage_category": "LEGAL_EXPENSE",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "중과실 사고로 피해자 형사합의 시 실제 합의금 보상",
            "aliases": ["교통사고처리지원금", "형사합의금", "교통사고처리지원금(동승자포함)"],
        },
        {
            "standard_code": "STD_DRIVER_CRIMINAL_DEFENSE",
            "coverage_name": "자동차사고변호사선임비용",
            "coverage_category": "LEGAL_EXPENSE",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "운전 중 사고로 구속영장 청구 또는 기소 시 실제 변호사선임비용 보상",
            "aliases": ["변호사선임비용", "자동차사고변호사선임비용", "운전자변호사선임비용"],
        },
        # 자동차
        {
            "standard_code": "STD_AUTO_OWN_DAMAGE",
            "coverage_name": "자동차 자기차량손해",
            "coverage_category": "PROPERTY_DAMAGE",
            "insurance_type": InsuranceType.AUTO,
            "description": "피보험자동차 직접 손해액 및 비용에서 자기부담금을 공제한 금액 보상",
            "aliases": ["자기차량손해", "자차손해", "자차", "자기차량손해담보"],
        },
        # 후유장해 (장해율 3%~100% 비례지급)
        {
            "standard_code": "STD_INJURY_DISABILITY_3_TO_100",
            "coverage_name": "상해후유장해(3~100%)",
            "coverage_category": "DISABILITY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": (
                "상해로 인하여 장해분류표에서 정한 3%~100% 장해지급률에 "
                "해당하는 장해상태 시 비례지급"
            ),
            "aliases": ["상해후유장해", "상해후유장해(3~100%)", "상해장해", "상해후유장해진단금"],
        },
        {
            "standard_code": "STD_DISEASE_DISABILITY_3_TO_100",
            "coverage_name": "질병후유장해(3~100%)",
            "coverage_category": "DISABILITY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": (
                "질병으로 인하여 장해분류표에서 정한 3%~100% 장해지급률에 "
                "해당하는 장해상태 시 비례지급"
            ),
            "aliases": ["질병후유장해", "질병후유장해(3~100%)", "질병장해", "질병후유장해진단금"],
        },
        # 실손의료비 (급여/비급여)
        {
            "standard_code": "STD_INDEMNITY_BENEFIT",
            "coverage_name": "질병/상해 급여 실손의료비",
            "coverage_category": "INDEMNITY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": (
                "질병 또는 상해 치료 시 국민건강보험 급여 본인부담금에서 공제율 적용 후 실손보상"
            ),
            "aliases": ["질병급여실손", "상해급여실손", "급여실손의료비", "급여의료비"],
        },
        {
            "standard_code": "STD_INDEMNITY_NON_BENEFIT",
            "coverage_name": "질병/상해 비급여 실손의료비",
            "coverage_category": "INDEMNITY",
            "insurance_type": InsuranceType.THIRD_PARTY,
            "description": "질병 또는 상해 치료 시 비급여 의료비에서 공제율 적용 후 실손보상",
            "aliases": ["질병비급여실손", "상해비급여실손", "비급여실손의료비", "3대비급여"],
        },
    ]

    coverage_map: dict[str, Coverage] = {}
    for cdef in standard_coverages_def:
        cov = db.execute(
            select(Coverage).where(Coverage.standard_code == cdef["standard_code"])
        ).scalar_one_or_none()
        if not cov:
            cov = Coverage(
                coverage_id=uuid.uuid4(),
                standard_code=cdef["standard_code"],
                coverage_name=cdef["coverage_name"],
                coverage_category=cdef["coverage_category"],
                insurance_type=cdef["insurance_type"],
                description=cdef["description"],
                status=MasterStatus.ACTIVE,
            )
            db.add(cov)
            db.flush()
            counts["coverages"] += 1
        coverage_map[str(cdef["standard_code"])] = cov

        for alias in cdef["aliases"]:
            existing_alias = db.execute(
                select(CoverageAlias).where(
                    CoverageAlias.coverage_id == cov.coverage_id,
                    CoverageAlias.company_id == company.company_id,
                    CoverageAlias.normalized_name == alias,
                )
            ).scalar_one_or_none()
            if not existing_alias:
                alias_obj = CoverageAlias(
                    alias_id=uuid.uuid4(),
                    coverage_id=cov.coverage_id,
                    company_id=company.company_id,
                    alias_name=alias,
                    normalized_name=alias,
                )
                db.add(alias_obj)
                counts["aliases"] += 1
    db.flush()

    # -------------------------------------------------------------
    # 4. Product 1: (무)프로미라이프 New간편암건강보험2601
    # -------------------------------------------------------------
    p1 = db.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "31201",
        )
    ).scalar_one_or_none()
    if not p1:
        p1 = InsuranceProduct(
            product_id=uuid.uuid4(),
            company_id=company.company_id,
            product_code="31201",
            product_name="무배당 프로미라이프 New간편암건강보험2601",
            insurance_type=InsuranceType.THIRD_PARTY,
            status=MasterStatus.ACTIVE,
        )
        db.add(p1)
        db.flush()
        counts["products"] += 1

    pv1 = db.execute(
        select(ProductVersion).where(
            ProductVersion.product_id == p1.product_id,
            ProductVersion.version_name == "2601",
        )
    ).scalar_one_or_none()
    if not pv1:
        pv1 = ProductVersion(
            product_version_id=uuid.uuid4(),
            product_id=p1.product_id,
            version_name="2601",
            sale_start_date=date(2026, 4, 1),
            effective_from=date(2026, 4, 1),
            status=VersionStatus.ACTIVE,
        )
        db.add(pv1)
        db.flush()
        counts["product_versions"] += 1

    pol1 = db.execute(
        select(Policy).where(Policy.product_version_id == pv1.product_version_id)
    ).scalar_one_or_none()
    if not pol1:
        pol1 = Policy(
            policy_id=uuid.uuid4(),
            product_version_id=pv1.product_version_id,
            policy_name="무배당 프로미라이프 New간편암건강보험2601 보통약관 및 특별약관",
            policy_type=PolicyType.GENERAL,
            status=MasterStatus.ACTIVE,
        )
        db.add(pol1)
        db.flush()
        counts["policies"] += 1

    polv1 = db.execute(
        select(PolicyVersion).where(
            PolicyVersion.policy_id == pol1.policy_id,
            PolicyVersion.version_code == "31084(03)",
        )
    ).scalar_one_or_none()
    if not polv1:
        polv1 = PolicyVersion(
            policy_version_id=uuid.uuid4(),
            policy_id=pol1.policy_id,
            version_code="31084(03)",
            effective_from=date(2026, 4, 1),
            file_hash="39cbc6761ee58a9ece32170f2759df71c76beb7e2bd1c5e73202bda817f5ac2d",
            source_file_uri="storage/policies/db_insurance/31201/2601/policy_31084_03_20260401.pdf",
            original_filename="policy_31084_03_20260401.pdf",
            status=PolicyVersionStatus.ACTIVE,
            approved_by=admin.user_id,
        )
        db.add(polv1)
        db.flush()
        counts["policy_versions"] += 1

    cancer_clauses_data = [
        {
            "article_number": "제3조",
            "article_title": "보험금의 지급사유",
            "clause_text": (
                "회사는 피보험자가 이 특별약관의 보험기간 중에 '암(유사암 제외)'으로 "
                "진단확정된 때에는 최초 1회에 한하여 아래의 금액을 암진단비로 지급합니다. "
                "보장개시일(계약일로부터 90일이 지난 날의 다음 날) 이후 100% 지급."
            ),
            "page_number": 79,
        },
        {
            "article_number": "제4조",
            "article_title": "암 및 유사암의 정의 및 진단확정",
            "clause_text": (
                "이 특약에서 '암'이라 함은 제8차 KCD 중 "
                "[별표2] 악성신생물 분류표(C00~C97)를 말합니다. "
                "단, 기타피부암(C44), 갑상선암(C73), 제자리암(D00~D09), "
                "경계성종양(D37~D48)은 제외합니다."
            ),
            "page_number": 79,
        },
        {
            "article_number": "제5조",
            "article_title": "유사암의 보장",
            "clause_text": (
                "회사는 피보험자가 '유사암'(기타피부암, 갑상선암, 제자리암, 경계성종양)으로 "
                "진단확정된 경우 각각 1회에 한하여 가입금액의 20%를 지급합니다. "
                "면책기간을 적용하지 않습니다."
            ),
            "page_number": 83,
        },
        {
            "article_number": "별표2",
            "article_title": "악성신생물(암) 분류표",
            "clause_text": (
                "악성신생물 분류표: C00~C14, C15~C26, C30~C39, C40~C41, C43, C45~C49, C50, "
                "C51~C58, C60~C63, C64~C68, C69~C72, C76~C80, C81~C96, C97, D45, D46, D47."
            ),
            "page_number": 203,
        },
    ]

    clause_map_p1: dict[str, PolicyClause] = {}
    for cdata in cancer_clauses_data:
        cl = db.execute(
            select(PolicyClause).where(
                PolicyClause.policy_version_id == polv1.policy_version_id,
                PolicyClause.article_number == cdata["article_number"],
            )
        ).scalar_one_or_none()
        if not cl:
            cl = PolicyClause(
                clause_id=uuid.uuid4(),
                policy_version_id=polv1.policy_version_id,
                article_number=cdata["article_number"],
                article_title=cdata["article_title"],
                clause_text=cdata["clause_text"],
                page_number=cdata["page_number"],
            )
            db.add(cl)
            db.flush()
            counts["clauses"] += 1
        clause_map_p1[str(cdata["article_number"])] = cl

    cancer_kcd_list = [
        "C00-C14",
        "C15-C26",
        "C30-C39",
        "C40-C41",
        "C43",
        "C45-C49",
        "C50",
        "C51-C58",
        "C60-C63",
        "C64-C68",
        "C69-C72",
        "C76-C80",
        "C81-C96",
        "C97",
        "C16",
        "C18",
        "C20",
        "C22",
        "C25",
        "C34",
        "C50",
        "C53",
        "C56",
        "C61",
        "C64",
        "D45",
        "D46",
        "D47.1",
        "D47.3",
        "D47.4",
        "D47.5",
    ]
    excluded_kcd_list = [
        "C44",
        "C73",
        "D00",
        "D01",
        "D02",
        "D03",
        "D04",
        "D05",
        "D06",
        "D07",
        "D08",
        "D09",
        "D37",
        "D38",
        "D39",
        "D40",
        "D41",
        "D42",
        "D43",
        "D44",
        "D47",
        "D48",
    ]

    # Rule 1: 암진단비 적격성 (ELIGIBILITY)
    r_cancer_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_CANCER_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv1.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_cancer_elig:
        r_cancer_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_CANCER_DIAG"].coverage_id,
            policy_version_id=polv1.policy_version_id,
            rule_name="일반암 진단비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_cancer_elig)
        db.flush()
        counts["rules"] += 1

        rv_cancer_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_cancer_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "IN",
                        "value": cancer_kcd_list,
                    }
                ],
            },
            effective_from=date(2026, 4, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_cancer_elig)
        db.flush()
        counts["rule_versions"] += 1

        c1 = RuleCondition(
            condition_id=uuid.uuid4(),
            rule_version_id=rv_cancer_elig.rule_version_id,
            sequence_no=1,
            fact_path="facts.DIAGNOSIS_CODE",
            operator=RuleOperator.IN,
            comparison_value=cancer_kcd_list,
            logical_operator=LogicalOperator.AND,
        )
        db.add(c1)
        counts["conditions"] += 1

        brc1 = BenefitRuleClause(
            link_id=uuid.uuid4(),
            rule_id=r_cancer_elig.rule_id,
            clause_id=clause_map_p1["제3조"].clause_id,
            relation_type="SOURCE",
        )
        brc2 = BenefitRuleClause(
            link_id=uuid.uuid4(),
            rule_id=r_cancer_elig.rule_id,
            clause_id=clause_map_p1["별표2"].clause_id,
            relation_type="APPENDIX",
        )
        db.add_all([brc1, brc2])

    # Rule 2: 암진단비 면책/제외 (EXCLUSION)
    r_cancer_excl = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_CANCER_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv1.policy_version_id,
            BenefitRule.rule_type == RuleType.EXCLUSION,
        )
    ).scalar_one_or_none()
    if not r_cancer_excl:
        r_cancer_excl = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_CANCER_DIAG"].coverage_id,
            policy_version_id=polv1.policy_version_id,
            rule_name="일반암 진단비 제외질병(유사암) 면책규칙",
            rule_type=RuleType.EXCLUSION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_cancer_excl)
        db.flush()
        counts["rules"] += 1

        rv_cancer_excl = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_cancer_excl.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "EXCLUSION",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "IN",
                        "value": excluded_kcd_list,
                    }
                ],
            },
            effective_from=date(2026, 4, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_cancer_excl)
        db.flush()
        counts["rule_versions"] += 1

        c_excl = RuleCondition(
            condition_id=uuid.uuid4(),
            rule_version_id=rv_cancer_excl.rule_version_id,
            sequence_no=1,
            fact_path="facts.DIAGNOSIS_CODE",
            operator=RuleOperator.IN,
            comparison_value=excluded_kcd_list,
            logical_operator=LogicalOperator.AND,
        )
        db.add(c_excl)
        counts["conditions"] += 1

        brc_excl = BenefitRuleClause(
            link_id=uuid.uuid4(),
            rule_id=r_cancer_excl.rule_id,
            clause_id=clause_map_p1["제4조"].clause_id,
            relation_type="SOURCE",
        )
        db.add(brc_excl)

    # Rule 3: 암진단비 계산 산식 (CALCULATION)
    r_cancer_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_CANCER_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv1.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_cancer_calc:
        r_cancer_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_CANCER_DIAG"].coverage_id,
            policy_version_id=polv1.policy_version_id,
            rule_name="일반암 진단비 100% 정액지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_cancer_calc)
        db.flush()
        counts["rules"] += 1

        rv_cancer_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_cancer_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2026, 4, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_cancer_calc)
        db.flush()
        counts["rule_versions"] += 1

    # Rule 4: 유사암 진단비
    r_sim_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_SIMILAR_CANCER_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv1.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_sim_elig:
        r_sim_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_SIMILAR_CANCER_DIAG"].coverage_id,
            policy_version_id=polv1.policy_version_id,
            rule_name="유사암 진단비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_sim_elig)
        db.flush()
        counts["rules"] += 1

        rv_sim_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_sim_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "IN",
                        "value": excluded_kcd_list,
                    }
                ],
            },
            effective_from=date(2026, 4, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_sim_elig)
        db.flush()
        counts["rule_versions"] += 1

        r_sim_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_SIMILAR_CANCER_DIAG"].coverage_id,
            policy_version_id=polv1.policy_version_id,
            rule_name="유사암 진단비 20% 정액지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_sim_calc)
        db.flush()
        counts["rules"] += 1

        rv_sim_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_sim_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "0.2",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2026, 4, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_sim_calc)
        db.flush()
        counts["rule_versions"] += 1

    # -------------------------------------------------------------
    # 5. Product 2: 프로미카 개인용자동차보험
    # -------------------------------------------------------------
    p2 = db.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "PROMY-AUTO",
        )
    ).scalar_one_or_none()
    if not p2:
        p2 = InsuranceProduct(
            product_id=uuid.uuid4(),
            company_id=company.company_id,
            product_code="PROMY-AUTO",
            product_name="프로미카 개인용자동차보험",
            insurance_type=InsuranceType.AUTO,
            status=MasterStatus.ACTIVE,
        )
        db.add(p2)
        db.flush()
        counts["products"] += 1

    pv2 = db.execute(
        select(ProductVersion).where(
            ProductVersion.product_id == p2.product_id,
            ProductVersion.version_name == "2024-02-22",
        )
    ).scalar_one_or_none()
    if not pv2:
        pv2 = ProductVersion(
            product_version_id=uuid.uuid4(),
            product_id=p2.product_id,
            version_name="2024-02-22",
            sale_start_date=date(2024, 2, 22),
            effective_from=date(2024, 2, 22),
            status=VersionStatus.ACTIVE,
        )
        db.add(pv2)
        db.flush()
        counts["product_versions"] += 1

    pol2 = db.execute(
        select(Policy).where(Policy.product_version_id == pv2.product_version_id)
    ).scalar_one_or_none()
    if not pol2:
        pol2 = Policy(
            policy_id=uuid.uuid4(),
            product_version_id=pv2.product_version_id,
            policy_name="프로미카 개인용자동차보험 보통약관",
            policy_type=PolicyType.GENERAL,
            status=MasterStatus.ACTIVE,
        )
        db.add(pol2)
        db.flush()
        counts["policies"] += 1

    polv2 = db.execute(
        select(PolicyVersion).where(
            PolicyVersion.policy_id == pol2.policy_id,
            PolicyVersion.version_code == "PROMY-20240222",
        )
    ).scalar_one_or_none()
    if not polv2:
        polv2 = PolicyVersion(
            policy_version_id=uuid.uuid4(),
            policy_id=pol2.policy_id,
            version_code="PROMY-20240222",
            effective_from=date(2024, 2, 22),
            file_hash="cb7e818b0d8988ae3e4229748f9b04a4eb3e61cd62dc420aba11f58c9a6b1aa9",
            source_file_uri="storage/policies/db_insurance/promica_auto_2024-02-22.pdf",
            original_filename="promica_auto_2024-02-22.pdf",
            status=PolicyVersionStatus.ACTIVE,
            approved_by=admin.user_id,
        )
        db.add(polv2)
        db.flush()
        counts["policy_versions"] += 1

    auto_clauses_data = [
        {
            "article_number": "제21조",
            "article_title": "보상하는 손해",
            "clause_text": (
                "자기차량손해에서 보험회사는 피보험자가 피보험자동차를 소유ㆍ사용ㆍ관리하는 동안에 "
                "발생한 사고로 생긴 손해를 가입금액 한도로 보상합니다."
            ),
            "page_number": 47,
        },
        {
            "article_number": "제23조",
            "article_title": "보상하지 않는 손해",
            "clause_text": (
                "고의로 인한 손해, 영리 목적 요금 수령 사용 시 손해 등은 보상하지 않습니다."
            ),
            "page_number": 47,
        },
        {
            "article_number": "제24조",
            "article_title": "지급보험금의 계산",
            "clause_text": "지급보험금은 손해액과 비용의 합에서 자기부담금을 공제한 후 지급합니다.",
            "page_number": 48,
        },
    ]

    for cdata in auto_clauses_data:
        cl = db.execute(
            select(PolicyClause).where(
                PolicyClause.policy_version_id == polv2.policy_version_id,
                PolicyClause.article_number == cdata["article_number"],
            )
        ).scalar_one_or_none()
        if not cl:
            cl = PolicyClause(
                clause_id=uuid.uuid4(),
                policy_version_id=polv2.policy_version_id,
                article_number=cdata["article_number"],
                article_title=cdata["article_title"],
                clause_text=cdata["clause_text"],
                page_number=cdata["page_number"],
            )
            db.add(cl)
            counts["clauses"] += 1

    # -------------------------------------------------------------
    # 6. Product 3: (무)프로미라이프 참좋은훼밀리종합보험 (뇌/심장/수술/골절/입원/배상책임)
    # -------------------------------------------------------------
    p3 = db.execute(
        select(InsuranceProduct).where(
            InsuranceProduct.company_id == company.company_id,
            InsuranceProduct.product_code == "31100",
        )
    ).scalar_one_or_none()
    if not p3:
        p3 = InsuranceProduct(
            product_id=uuid.uuid4(),
            company_id=company.company_id,
            product_code="31100",
            product_name="무배당 프로미라이프 참좋은훼밀리종합보험",
            insurance_type=InsuranceType.THIRD_PARTY,
            status=MasterStatus.ACTIVE,
        )
        db.add(p3)
        db.flush()
        counts["products"] += 1

    pv3 = db.execute(
        select(ProductVersion).where(
            ProductVersion.product_id == p3.product_id,
            ProductVersion.version_name == "2401",
        )
    ).scalar_one_or_none()
    if not pv3:
        pv3 = ProductVersion(
            product_version_id=uuid.uuid4(),
            product_id=p3.product_id,
            version_name="2401",
            sale_start_date=date(2024, 1, 1),
            effective_from=date(2024, 1, 1),
            status=VersionStatus.ACTIVE,
        )
        db.add(pv3)
        db.flush()
        counts["product_versions"] += 1

    pol3 = db.execute(
        select(Policy).where(Policy.product_version_id == pv3.product_version_id)
    ).scalar_one_or_none()
    if not pol3:
        pol3 = Policy(
            policy_id=uuid.uuid4(),
            product_version_id=pv3.product_version_id,
            policy_name="무배당 프로미라이프 참좋은훼밀리종합보험 보통약관 및 특별약관",
            policy_type=PolicyType.GENERAL,
            status=MasterStatus.ACTIVE,
        )
        db.add(pol3)
        db.flush()
        counts["policies"] += 1

    polv3 = db.execute(
        select(PolicyVersion).where(
            PolicyVersion.policy_id == pol3.policy_id,
            PolicyVersion.version_code == "31100-2401",
        )
    ).scalar_one_or_none()
    if not polv3:
        polv3 = PolicyVersion(
            policy_version_id=uuid.uuid4(),
            policy_id=pol3.policy_id,
            version_code="31100-2401",
            effective_from=date(2024, 1, 1),
            status=PolicyVersionStatus.ACTIVE,
            approved_by=admin.user_id,
        )
        db.add(polv3)
        db.flush()
        counts["policy_versions"] += 1

    # Clauses for Product 3
    p3_clauses_def = [
        {
            "article_number": "특약_제10조",
            "article_title": "뇌출혈 진단비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 '뇌출혈'(I60~I62)로 진단확정된 때에는 "
                "최초 1회에 한하여 가입금액의 100%를 지급합니다."
            ),
            "page_number": 110,
        },
        {
            "article_number": "특약_제12조",
            "article_title": "뇌졸중 진단비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 '뇌졸중'(I60~I63, I65, I66)으로 진단확정 시 "
                "최초 1회에 한하여 가입금액의 100%를 지급합니다."
            ),
            "page_number": 114,
        },
        {
            "article_number": "특약_제15조",
            "article_title": "뇌혈관질환 진단비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 '뇌혈관질환'(I60~I69)으로 진단확정 시 "
                "최초 1회에 한하여 가입금액의 100%를 지급합니다."
            ),
            "page_number": 118,
        },
        {
            "article_number": "특약_제20조",
            "article_title": "급성심근경색증 진단비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 '급성심근경색증'(I21~I23)으로 진단확정 시 "
                "최초 1회에 한하여 가입금액의 100%를 지급합니다."
            ),
            "page_number": 125,
        },
        {
            "article_number": "특약_제22조",
            "article_title": "허혈성심장질환 진단비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 '허혈성심장질환'(I20~I25, 협심증 포함)으로 진단확정 시 "
                "최초 1회에 한하여 가입금액의 100%를 지급합니다."
            ),
            "page_number": 128,
        },
        {
            "article_number": "특약_제30조",
            "article_title": "질병수술비의 지급사유",
            "clause_text": (
                "피보험자가 보험기간 중 질병으로 수술을 받은 경우 매 수술 1회당 "
                "가입금액의 100%를 지급합니다."
            ),
            "page_number": 140,
        },
        {
            "article_number": "특약_제35조",
            "article_title": "골절진단비(치아파절제외)의 지급사유",
            "clause_text": (
                "피보험자가 상해로 골절(치아파절 제외, S코드) 진단확정 시 "
                "사고 1회당 가입금액의 100%를 지급합니다."
            ),
            "page_number": 152,
        },
        {
            "article_number": "특약_제40조",
            "article_title": "질병입원일당의 지급사유",
            "clause_text": (
                "피보험자가 질병으로 입원하여 치료를 받은 경우 입원 1일당 가입금액을 "
                "1회 입원당 180일 한도로 지급합니다."
            ),
            "page_number": 160,
        },
        {
            "article_number": "특약_제50조",
            "article_title": "가족일상생활배상책임의 보상하는 손해",
            "clause_text": (
                "피보험자가 주택의 소유, 사용, 관리 또는 일상생활에 기인하는 사고로 "
                "타인의 신체나 재물에 손해를 입혀 배상책임을 부담함으로써 입은 손해를 보상합니다."
            ),
            "page_number": 170,
        },
        {
            "article_number": "특약_제52조",
            "article_title": "가족일상생활배상책임의 보상하지 않는 손해",
            "clause_text": (
                "피보험자의 고의로 생긴 손해, 직무수행에 직접 기인하는 배상책임, "
                "피보험자와 세대를 같이하는 친족에 대한 배상책임 등은 보상하지 않습니다."
            ),
            "page_number": 172,
        },
        {
            "article_number": "특약_제54조",
            "article_title": "가족일상생활배상책임의 지급보험금의 계산",
            "clause_text": (
                "손해액에서 자기부담금(대물 누수 50만원, 기타 대물 20만원, 대인 0원)을 "
                "공제한 후 보험가입금액 한도 내에서 지급합니다."
            ),
            "page_number": 174,
        },
        {
            "article_number": "특약_제60조",
            "article_title": "교통사고처리지원금의 지급사유",
            "clause_text": (
                "피보험자가 운전 중 타인을 사망 또는 중상해에 이르게 하거나 "
                "12대 중과실 사고로 형사합의 시 실제 합의금을 한도 내 지급합니다."
            ),
            "page_number": 185,
        },
        {
            "article_number": "특약_제62조",
            "article_title": "자동차사고 변호사선임비용의 지급사유",
            "clause_text": (
                "피보험자가 운전 중 사고로 구속영장에 의해 구속되거나 "
                "공판청구된 경우 실제 변호사선임비용을 가입금액 한도로 지급합니다."
            ),
            "page_number": 190,
        },
    ]

    clause_map_p3: dict[str, PolicyClause] = {}
    for cdata in p3_clauses_def:
        cl = db.execute(
            select(PolicyClause).where(
                PolicyClause.policy_version_id == polv3.policy_version_id,
                PolicyClause.article_number == cdata["article_number"],
            )
        ).scalar_one_or_none()
        if not cl:
            cl = PolicyClause(
                clause_id=uuid.uuid4(),
                policy_version_id=polv3.policy_version_id,
                article_number=cdata["article_number"],
                article_title=cdata["article_title"],
                clause_text=cdata["clause_text"],
                page_number=cdata["page_number"],
            )
            db.add(cl)
            db.flush()
            counts["clauses"] += 1
        clause_map_p3[str(cdata["article_number"])] = cl

    # Rider Rules Definition Helper
    def create_rider_rules(
        cov_key: str,
        rule_name_prefix: str,
        kcd_list: list[str],
        payment_rate: str = "1.0",
        clause_art: str | None = None,
    ) -> None:
        cov = coverage_map[cov_key]
        r_elig = db.execute(
            select(BenefitRule).where(
                BenefitRule.coverage_id == cov.coverage_id,
                BenefitRule.policy_version_id == polv3.policy_version_id,
                BenefitRule.rule_type == RuleType.ELIGIBILITY,
            )
        ).scalar_one_or_none()
        if not r_elig:
            r_elig = BenefitRule(
                rule_id=uuid.uuid4(),
                coverage_id=cov.coverage_id,
                policy_version_id=polv3.policy_version_id,
                rule_name=f"{rule_name_prefix} 지급요건 평가규칙",
                rule_type=RuleType.ELIGIBILITY,
                status=RuleStatus.ACTIVE,
            )
            db.add(r_elig)
            db.flush()
            counts["rules"] += 1

            rv_elig = RuleVersion(
                rule_version_id=uuid.uuid4(),
                rule_id=r_elig.rule_id,
                version_no=1,
                rule_definition={
                    "schemaVersion": "1.0",
                    "ruleType": "ELIGIBILITY",
                    "logicalOperator": "AND",
                    "conditions": [
                        {
                            "path": "facts.DIAGNOSIS_CODE",
                            "operator": "IN",
                            "value": kcd_list,
                        }
                    ],
                },
                effective_from=date(2024, 1, 1),
                status=RuleStatus.ACTIVE,
                source_type=RuleSourceType.MANUAL,
                created_by=admin.user_id,
                approved_by=admin.user_id,
            )
            db.add(rv_elig)
            db.flush()
            counts["rule_versions"] += 1

            cond = RuleCondition(
                condition_id=uuid.uuid4(),
                rule_version_id=rv_elig.rule_version_id,
                sequence_no=1,
                fact_path="facts.DIAGNOSIS_CODE",
                operator=RuleOperator.IN,
                comparison_value=kcd_list,
                logical_operator=LogicalOperator.AND,
            )
            db.add(cond)
            counts["conditions"] += 1

            if clause_art and clause_art in clause_map_p3:
                brc = BenefitRuleClause(
                    link_id=uuid.uuid4(),
                    rule_id=r_elig.rule_id,
                    clause_id=clause_map_p3[clause_art].clause_id,
                    relation_type="SOURCE",
                )
                db.add(brc)

        r_calc = db.execute(
            select(BenefitRule).where(
                BenefitRule.coverage_id == cov.coverage_id,
                BenefitRule.policy_version_id == polv3.policy_version_id,
                BenefitRule.rule_type == RuleType.CALCULATION,
            )
        ).scalar_one_or_none()
        if not r_calc:
            r_calc = BenefitRule(
                rule_id=uuid.uuid4(),
                coverage_id=cov.coverage_id,
                policy_version_id=polv3.policy_version_id,
                rule_name=f"{rule_name_prefix} {payment_rate} 정액지급 산정규칙",
                rule_type=RuleType.CALCULATION,
                status=RuleStatus.ACTIVE,
            )
            db.add(r_calc)
            db.flush()
            counts["rules"] += 1

            rv_calc = RuleVersion(
                rule_version_id=uuid.uuid4(),
                rule_id=r_calc.rule_id,
                version_no=1,
                rule_definition={
                    "schemaVersion": 1,
                    "ruleType": "CALCULATION",
                    "strategy": "FIXED_BENEFIT",
                    "parameters": {
                        "paymentRate": payment_rate,
                        "deductionAmount": 0,
                        "roundingMode": "DOWN",
                        "roundingUnit": 1,
                    },
                },
                effective_from=date(2024, 1, 1),
                status=RuleStatus.ACTIVE,
                source_type=RuleSourceType.MANUAL,
                created_by=admin.user_id,
                approved_by=admin.user_id,
            )
            db.add(rv_calc)
            db.flush()
            counts["rule_versions"] += 1

    # 1) 뇌출혈진단비
    create_rider_rules(
        "STD_CEREBRAL_HEMORRHAGE_DIAG",
        "뇌출혈 진단비",
        ["I60", "I61", "I62", "I60.0", "I60.9", "I61.0", "I61.9", "I62.0", "I62.9"],
        "1.0",
        "특약_제10조",
    )

    # 2) 뇌졸중진단비
    create_rider_rules(
        "STD_STROKE_DIAG",
        "뇌졸중 진단비",
        ["I60", "I61", "I62", "I63", "I65", "I66", "I63.0", "I63.9"],
        "1.0",
        "특약_제12조",
    )

    # 3) 뇌혈관질환진단비
    create_rider_rules(
        "STD_CEREBROVASCULAR_DIAG",
        "뇌혈관질환 진단비",
        ["I60", "I61", "I62", "I63", "I64", "I65", "I66", "I67", "I68", "I69", "I67.1", "I67.2"],
        "1.0",
        "특약_제15조",
    )

    # 4) 급성심근경색증진단비
    create_rider_rules(
        "STD_ACUTE_MYOCARDIAL_INFARCTION_DIAG",
        "급성심근경색증 진단비",
        ["I21", "I22", "I23", "I21.0", "I21.9", "I22.0", "I23.0"],
        "1.0",
        "특약_제20조",
    )

    # 5) 허혈성심장질환진단비
    create_rider_rules(
        "STD_ISCHEMIC_HEART_DIAG",
        "허혈성심장질환 진단비",
        ["I20", "I21", "I22", "I23", "I24", "I25", "I20.0", "I20.9", "I25.1", "I25.9"],
        "1.0",
        "특약_제22조",
    )

    # 6) 뇌혈관질환수술비
    create_rider_rules(
        "STD_CEREBROVASCULAR_SURGERY",
        "뇌혈관질환 수술비",
        ["I60", "I61", "I62", "I63", "I64", "I65", "I66", "I67", "I68", "I69"],
        "1.0",
        "특약_제15조",
    )

    # 7) 허혈성심장질환수술비
    create_rider_rules(
        "STD_ISCHEMIC_HEART_SURGERY",
        "허혈성심장질환 수술비",
        ["I20", "I21", "I22", "I23", "I24", "I25"],
        "1.0",
        "특약_제22조",
    )

    # 8) 질병수술비
    r_surg_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_DISEASE_SURGERY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_surg_elig:
        r_surg_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DISEASE_SURGERY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="질병수술비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_surg_elig)
        db.flush()
        counts["rules"] += 1

        rv_surg_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_surg_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.SURGERY_NAME",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_surg_elig)
        db.flush()
        counts["rule_versions"] += 1

    r_surg_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_DISEASE_SURGERY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_surg_calc:
        r_surg_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DISEASE_SURGERY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="질병수술비 100% 정액지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_surg_calc)
        db.flush()
        counts["rules"] += 1

        rv_surg_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_surg_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_surg_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 상해수술비
    r_inj_surg_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_INJURY_SURGERY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_inj_surg_elig:
        r_inj_surg_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INJURY_SURGERY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="상해수술비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_inj_surg_elig)
        db.flush()
        counts["rules"] += 1

        rv_inj_surg_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_inj_surg_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.SURGERY_NAME",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_inj_surg_elig)
        db.flush()
        counts["rule_versions"] += 1

    r_inj_surg_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_INJURY_SURGERY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_inj_surg_calc:
        r_inj_surg_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INJURY_SURGERY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="상해수술비 100% 정액지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_inj_surg_calc)
        db.flush()
        counts["rules"] += 1

        rv_inj_surg_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_inj_surg_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_inj_surg_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 9) 골절진단비
    r_frac_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_FRACTURE_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_frac_elig:
        r_frac_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_FRACTURE_DIAG"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="골절진단비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_frac_elig)
        db.flush()
        counts["rules"] += 1

        rv_frac_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_frac_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_frac_elig)
        db.flush()
        counts["rule_versions"] += 1
    r_frac_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_FRACTURE_DIAG"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_frac_calc:
        r_frac_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_FRACTURE_DIAG"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="골절진단비 100% 정액지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_frac_calc)
        db.flush()
        counts["rules"] += 1

        rv_frac_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_frac_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_frac_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 10) 질병입원일당
    r_hosp_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_DISEASE_HOSPITAL_DAY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_hosp_calc:
        r_hosp_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DISEASE_HOSPITAL_DAY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="질병입원일당 일수비례 산정규칙 (최대 180일)",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_hosp_calc)
        db.flush()
        counts["rules"] += 1

        rv_hosp_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_hosp_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "HOSPITAL_DAILY",
                "parameters": {
                    "dailyAmountSource": "CONTRACT_COVERAGE_INSURED_AMOUNT",
                    "dayCalculationMethod": "INCLUSIVE",
                    "maxDays": 180,
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_hosp_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 11) 가족일상생활배상책임 (STD_PERSONAL_LIABILITY)
    r_liab_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_PERSONAL_LIABILITY"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_liab_elig:
        r_liab_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_PERSONAL_LIABILITY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="가족일상생활배상책임 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_liab_elig)
        db.flush()
        counts["rules"] += 1

        rv_liab_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_liab_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.accident.liability_type",
                        "operator": "IN",
                        "value": ["BODILY_INJURY", "PROPERTY_DAMAGE", "WATER_LEAK"],
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_liab_elig)
        db.flush()
        counts["rule_versions"] += 1

        cond_liab = RuleCondition(
            condition_id=uuid.uuid4(),
            rule_version_id=rv_liab_elig.rule_version_id,
            sequence_no=1,
            fact_path="facts.accident.liability_type",
            operator=RuleOperator.IN,
            comparison_value=["BODILY_INJURY", "PROPERTY_DAMAGE", "WATER_LEAK"],
            logical_operator=LogicalOperator.AND,
        )
        db.add(cond_liab)
        counts["conditions"] += 1

        brc_liab = BenefitRuleClause(
            link_id=uuid.uuid4(),
            rule_id=r_liab_elig.rule_id,
            clause_id=clause_map_p3["특약_제50조"].clause_id,
            relation_type="SOURCE",
        )
        db.add(brc_liab)

        r_liab_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_PERSONAL_LIABILITY"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="가족일상생활배상책임 실손(자기부담금 공제) 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_liab_calc)
        db.flush()
        counts["rules"] += 1

        rv_liab_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_liab_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 200000,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_liab_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 12) 교통사고처리지원금 (STD_DRIVER_TRAFFIC_ACCIDENT_SUPPORT)
    r_ts_calc = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id
            == coverage_map["STD_DRIVER_TRAFFIC_ACCIDENT_SUPPORT"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.CALCULATION,
        )
    ).scalar_one_or_none()
    if not r_ts_calc:
        r_ts_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DRIVER_TRAFFIC_ACCIDENT_SUPPORT"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="교통사고처리지원금 실손합의금 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_ts_calc)
        db.flush()
        counts["rules"] += 1

        rv_ts_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_ts_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "FIXED_BENEFIT",
                "parameters": {
                    "paymentRate": "1.0",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_ts_calc)
        db.flush()
        counts["rule_versions"] += 1
    # 13) 상해후유장해 (STD_INJURY_DISABILITY_3_TO_100)
    r_inj_dis_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_INJURY_DISABILITY_3_TO_100"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_inj_dis_elig:
        r_inj_dis_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INJURY_DISABILITY_3_TO_100"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="상해후유장해(3~100%) 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_inj_dis_elig)
        db.flush()
        counts["rules"] += 1

        rv_inj_dis_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_inj_dis_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.ACCIDENT_DATE",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_inj_dis_elig)
        db.flush()
        counts["rule_versions"] += 1

        r_inj_dis_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INJURY_DISABILITY_3_TO_100"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="상해후유장해 3~100% 비례지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_inj_dis_calc)
        db.flush()
        counts["rules"] += 1

        rv_inj_dis_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_inj_dis_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "PROPORTIONAL_DISABILITY",
                "parameters": {
                    "minDisabilityRate": "0.03",
                    "maxDisabilityRate": "1.00",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_inj_dis_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 14) 질병후유장해 (STD_DISEASE_DISABILITY_3_TO_100)
    r_dis_dis_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_DISEASE_DISABILITY_3_TO_100"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_dis_dis_elig:
        r_dis_dis_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DISEASE_DISABILITY_3_TO_100"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="질병후유장해(3~100%) 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_dis_dis_elig)
        db.flush()
        counts["rules"] += 1

        rv_dis_dis_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_dis_dis_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_DATE",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_dis_dis_elig)
        db.flush()
        counts["rule_versions"] += 1

        r_dis_dis_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_DISEASE_DISABILITY_3_TO_100"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="질병후유장해 3~100% 비례지급 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_dis_dis_calc)
        db.flush()
        counts["rules"] += 1

        rv_dis_dis_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_dis_dis_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "PROPORTIONAL_DISABILITY",
                "parameters": {
                    "minDisabilityRate": "0.03",
                    "maxDisabilityRate": "1.00",
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_dis_dis_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 15) 실손의료비 급여 (STD_INDEMNITY_BENEFIT)
    r_med_ben_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_INDEMNITY_BENEFIT"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_med_ben_elig:
        r_med_ben_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INDEMNITY_BENEFIT"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="급여 실손의료비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_med_ben_elig)
        db.flush()
        counts["rules"] += 1

        rv_med_ben_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_med_ben_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_med_ben_elig)
        db.flush()
        counts["rule_versions"] += 1

        r_med_ben_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INDEMNITY_BENEFIT"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="급여 실손의료비 (20% 공제) 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_med_ben_calc)
        db.flush()
        counts["rules"] += 1

        rv_med_ben_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_med_ben_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "MEDICAL_EXPENSE",
                "parameters": {
                    "expenseType": "BENEFIT",
                    "copaymentRate": "0.20",
                    "minDeductionAmount": 10000,
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_med_ben_calc)
        db.flush()
        counts["rule_versions"] += 1

    # 16) 실손의료비 비급여 (STD_INDEMNITY_NON_BENEFIT)
    r_med_non_elig = db.execute(
        select(BenefitRule).where(
            BenefitRule.coverage_id == coverage_map["STD_INDEMNITY_NON_BENEFIT"].coverage_id,
            BenefitRule.policy_version_id == polv3.policy_version_id,
            BenefitRule.rule_type == RuleType.ELIGIBILITY,
        )
    ).scalar_one_or_none()
    if not r_med_non_elig:
        r_med_non_elig = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INDEMNITY_NON_BENEFIT"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="비급여 실손의료비 지급요건 평가규칙",
            rule_type=RuleType.ELIGIBILITY,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_med_non_elig)
        db.flush()
        counts["rules"] += 1

        rv_med_non_elig = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_med_non_elig.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": "1.0",
                "ruleType": "ELIGIBILITY",
                "logicalOperator": "AND",
                "conditions": [
                    {
                        "path": "facts.DIAGNOSIS_CODE",
                        "operator": "EXISTS",
                        "value": None,
                    }
                ],
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_med_non_elig)
        db.flush()
        counts["rule_versions"] += 1

        r_med_non_calc = BenefitRule(
            rule_id=uuid.uuid4(),
            coverage_id=coverage_map["STD_INDEMNITY_NON_BENEFIT"].coverage_id,
            policy_version_id=polv3.policy_version_id,
            rule_name="비급여 실손의료비 (30% 공제) 산정규칙",
            rule_type=RuleType.CALCULATION,
            status=RuleStatus.ACTIVE,
        )
        db.add(r_med_non_calc)
        db.flush()
        counts["rules"] += 1

        rv_med_non_calc = RuleVersion(
            rule_version_id=uuid.uuid4(),
            rule_id=r_med_non_calc.rule_id,
            version_no=1,
            rule_definition={
                "schemaVersion": 1,
                "ruleType": "CALCULATION",
                "strategy": "MEDICAL_EXPENSE",
                "parameters": {
                    "expenseType": "NON_BENEFIT",
                    "copaymentRate": "0.30",
                    "minDeductionAmount": 30000,
                    "deductionAmount": 0,
                    "roundingMode": "DOWN",
                    "roundingUnit": 1,
                },
            },
            effective_from=date(2024, 1, 1),
            status=RuleStatus.ACTIVE,
            source_type=RuleSourceType.MANUAL,
            created_by=admin.user_id,
            approved_by=admin.user_id,
        )
        db.add(rv_med_non_calc)
        db.flush()
        counts["rule_versions"] += 1

    db.commit()
    return counts


if __name__ == "__main__":
    with SessionLocal() as session:
        result = seed_db_insurance_master(session)
        print("DB Insurance Master Seed Completed:")
        for k, v in result.items():
            print(f"  - {k}: {v}")
