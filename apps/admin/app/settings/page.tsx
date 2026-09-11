"use client";

import Link from "next/link";
import { useState } from "react";

export interface AdjusterProfileSettings {
  name: string;
  license: string;
  office: string;
  contact: string;
  stampType: "circular" | "oval" | "custom";
  customStampImage: string; // Base64 data URL
  stampRotation: number; // degrees, e.g. -8
  showStampByDefault: boolean;
  showWatermarkByDefault: boolean;
  noticeStatement: string;
}

export const DEFAULT_ADJUSTER_SETTINGS: AdjusterProfileSettings = {
  name: "공인 손해사정사",
  license: "제1종·제4종 손해사정사 (등록번호: 제2026-0818호)",
  office: "바로 손해사정연구소 (Baro ClaimLens)",
  contact: "02-1588-0000 / support@baroproject.local",
  stampType: "circular",
  customStampImage: "",
  stampRotation: -8,
  showStampByDefault: true,
  showWatermarkByDefault: false,
  noticeStatement:
    "본 손해사정보고서는 보험업법 제188조 및 해당 보험약관에 의거하여 피보험자가 제출한 서류 및 의료기록 사실에 기초하여 신의성실의 원칙에 따라 공정하게 작성되었습니다.",
};

export const SETTINGS_STORAGE_KEY = "claimlens_adjuster_profile";

export default function AdjusterSettingsPage() {
  const [settings, setSettings] = useState<AdjusterProfileSettings>(() => {
    if (typeof window === "undefined") return DEFAULT_ADJUSTER_SETTINGS;
    try {
      const raw = localStorage.getItem(SETTINGS_STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        return { ...DEFAULT_ADJUSTER_SETTINGS, ...parsed };
      }
    } catch {
      // Use defaults
    }
    return DEFAULT_ADJUSTER_SETTINGS;
  });
  const [savedNotice, setSavedNotice] = useState(false);
  const [stampPreviewError, setStampPreviewError] = useState("");

  function handleSave() {
    try {
      localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
      setSavedNotice(true);
      setTimeout(() => setSavedNotice(false), 3000);
    } catch {
      alert("설정 저장 중 오류가 발생했습니다. 브라우저 저장용량을 확인해 주세요.");
    }
  }

  function handleReset() {
    if (confirm("모든 설정을 초기 표준값으로 복원하시겠습니까?")) {
      setSettings(DEFAULT_ADJUSTER_SETTINGS);
      localStorage.removeItem(SETTINGS_STORAGE_KEY);
      setSavedNotice(true);
      setTimeout(() => setSavedNotice(false), 3000);
    }
  }

  function handleImageUpload(e: React.ChangeEvent<HTMLInputElement>) {
    setStampPreviewError("");
    const file = e.target.files?.[0];
    if (!file) return;

    if (!file.type.startsWith("image/")) {
      setStampPreviewError("이미지 파일(PNG, JPG)만 등록할 수 있습니다.");
      return;
    }

    if (file.size > 2 * 1024 * 1024) {
      setStampPreviewError("직인 이미지는 2MB 이하 파일만 권장합니다.");
      return;
    }

    const reader = new FileReader();
    reader.onload = (uploadEvent) => {
      const dataUrl = uploadEvent.target?.result as string;
      setSettings((prev) => ({
        ...prev,
        stampType: "custom",
        customStampImage: dataUrl,
      }));
    };
    reader.readAsDataURL(file);
  }

  return (
    <main style={{ padding: "40px", maxWidth: "980px", margin: "0 auto" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "24px" }}>
        <div>
          <h1 style={{ margin: "0 0 8px 0", fontSize: "24px", color: "#101828" }}>
            ⚙️ 손해사정사 프로필 및 직인 설정
          </h1>
          <p style={{ margin: 0, color: "#667085", fontSize: "14px" }}>
            손해사정보고서(A4 출력용)에 인쇄될 담당 손해사정사 인적사항, 직인(도장) 도안, 기본 양식 옵션을 관리합니다.
          </p>
        </div>
        <div style={{ display: "flex", gap: "10px" }}>
          <Link
            href="/reviews"
            style={{
              padding: "10px 16px",
              background: "#475467",
              color: "white",
              borderRadius: "6px",
              textDecoration: "none",
              fontSize: "14px",
            }}
          >
            ← 심사 목록
          </Link>
          <button
            onClick={handleSave}
            style={{
              padding: "10px 20px",
              background: "#155eef",
              color: "white",
              fontWeight: "bold",
              fontSize: "14px",
              borderRadius: "6px",
            }}
          >
            💾 설정 저장
          </button>
        </div>
      </div>

      {savedNotice && (
        <div
          style={{
            padding: "14px 18px",
            background: "#ecfdf3",
            border: "1px solid #a6f4c5",
            borderRadius: "8px",
            color: "#067647",
            fontWeight: "bold",
            fontSize: "14px",
            marginBottom: "20px",
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
          }}
        >
          <span>✓ 설정이 성공적으로 저장되었습니다. 이후 생성 및 인쇄되는 모든 손해사정보고서에 즉시 반영됩니다.</span>
        </div>
      )}

      {/* Section 1: Basic Information */}
      <section className="card" style={{ marginBottom: "24px" }}>
        <h2 style={{ margin: "0 0 16px 0", fontSize: "18px", color: "#1d2939" }}>
          1. 손해사정사 인적사항 및 소속
        </h2>
        <div className="grid">
          <label>
            손해사정사 성명 *
            <input
              type="text"
              value={settings.name}
              onChange={(e) => setSettings({ ...settings, name: e.target.value })}
              placeholder="예: 홍길동"
              required
            />
          </label>
          <label>
            자격 구분 및 등록번호 *
            <input
              type="text"
              value={settings.license}
              onChange={(e) => setSettings({ ...settings, license: e.target.value })}
              placeholder="예: 제1종·제4종 손해사정사 (등록번호: 제2026-0818호)"
              required
            />
          </label>
          <label>
            소속 손해사정법인 / 사무소명 *
            <input
              type="text"
              value={settings.office}
              onChange={(e) => setSettings({ ...settings, office: e.target.value })}
              placeholder="예: 바로 손해사정연구소"
              required
            />
          </label>
          <label>
            대표 연락처 및 이메일
            <input
              type="text"
              value={settings.contact}
              onChange={(e) => setSettings({ ...settings, contact: e.target.value })}
              placeholder="예: 02-1588-0000 / adjuster@baro.kr"
            />
          </label>
        </div>
      </section>

      {/* Section 2: Seal / Stamp Design */}
      <section className="card" style={{ marginBottom: "24px" }}>
        <h2 style={{ margin: "0 0 16px 0", fontSize: "18px", color: "#1d2939" }}>
          2. 손해사정사 직인(인영) 및 서명 도안
        </h2>

        <div style={{ display: "grid", gridTemplateColumns: "1.2fr 1fr", gap: "24px", alignItems: "start" }}>
          <div>
            <div style={{ marginBottom: "16px" }}>
              <span style={{ fontWeight: "bold", display: "block", marginBottom: "8px" }}>직인 도안 선택</span>
              <div style={{ display: "flex", gap: "12px" }}>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
                  <input
                    type="radio"
                    name="stampType"
                    value="circular"
                    checked={settings.stampType === "circular"}
                    onChange={() => setSettings({ ...settings, stampType: "circular" })}
                  />
                  원형 직인 (전통 인영)
                </label>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
                  <input
                    type="radio"
                    name="stampType"
                    value="oval"
                    checked={settings.stampType === "oval"}
                    onChange={() => setSettings({ ...settings, stampType: "oval" })}
                  />
                  타원형 직인 (법인/등록)
                </label>
                <label style={{ display: "flex", alignItems: "center", gap: "6px", cursor: "pointer" }}>
                  <input
                    type="radio"
                    name="stampType"
                    value="custom"
                    checked={settings.stampType === "custom"}
                    onChange={() => setSettings({ ...settings, stampType: "custom" })}
                  />
                  실제 직인 이미지 업로드
                </label>
              </div>
            </div>

            {settings.stampType === "custom" && (
              <div
                style={{
                  padding: "16px",
                  background: "#f8fafc",
                  border: "1px dashed #cbd5e1",
                  borderRadius: "8px",
                  marginBottom: "16px",
                }}
              >
                <label style={{ display: "block", marginBottom: "8px", fontWeight: "bold", fontSize: "13px" }}>
                  직인 투명 PNG 이미지 등록 (배경 투명 권장, 최대 2MB)
                </label>
                <input type="file" accept="image/png,image/jpeg,image/webp" onChange={handleImageUpload} />
                {stampPreviewError && <p className="error" style={{ fontSize: "12px", marginTop: "6px" }}>{stampPreviewError}</p>}
                {settings.customStampImage && (
                  <button
                    type="button"
                    onClick={() => setSettings({ ...settings, customStampImage: "", stampType: "circular" })}
                    style={{ background: "#98a2b3", fontSize: "12px", padding: "4px 8px", marginTop: "8px" }}
                  >
                    등록된 이미지 제거
                  </button>
                )}
              </div>
            )}

            <div style={{ marginTop: "16px" }}>
              <label style={{ display: "block", fontSize: "13px", fontWeight: "bold", marginBottom: "6px" }}>
                직인 날인 회전 각도: {settings.stampRotation}° (수제 날인 효과)
              </label>
              <input
                type="range"
                min="-25"
                max="25"
                value={settings.stampRotation}
                onChange={(e) => setSettings({ ...settings, stampRotation: Number(e.target.value) })}
                style={{ width: "100%", maxWidth: "300px" }}
              />
            </div>
          </div>

          {/* Real-time Seal Preview Box */}
          <div
            style={{
              background: "#ffffff",
              border: "1px solid #eaecf0",
              borderRadius: "10px",
              padding: "20px",
              textAlign: "center",
              boxShadow: "0 2px 6px rgba(0,0,0,0.04)",
            }}
          >
            <span style={{ fontSize: "13px", fontWeight: "bold", color: "#475467", display: "block", marginBottom: "16px" }}>
              [손해사정보고서 하단 날인 미리보기]
            </span>

            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                gap: "16px",
                padding: "20px 0",
              }}
            >
              <div style={{ textAlign: "right", fontSize: "13px", lineHeight: "1.6" }}>
                <div>소 속: <strong>{settings.office || "소속명"}</strong></div>
                <div>자 격: <strong>{settings.license || "자격번호"}</strong></div>
                <div>손해사정사: <strong style={{ fontSize: "15px", letterSpacing: "2px" }}>{settings.name || "성명"}</strong></div>
              </div>

              {/* Seal Rendering */}
              {settings.stampType === "custom" && settings.customStampImage ? (
                <div
                  style={{
                    width: "72px",
                    height: "72px",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    transform: `rotate(${settings.stampRotation}deg)`,
                  }}
                >
                  {/* eslint-disable-next-line @next/next/no-img-element */}
                  <img
                    src={settings.customStampImage}
                    alt="손해사정사 직인"
                    style={{ maxWidth: "72px", maxHeight: "72px", objectFit: "contain" }}
                  />
                </div>
              ) : settings.stampType === "oval" ? (
                <div
                  style={{
                    width: "80px",
                    height: "56px",
                    border: "3px solid #dc2626",
                    borderRadius: "50%",
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "center",
                    alignItems: "center",
                    color: "#dc2626",
                    fontSize: "11px",
                    fontWeight: "bold",
                    lineHeight: "1.2",
                    transform: `rotate(${settings.stampRotation}deg)`,
                    boxShadow: "inset 0 0 3px rgba(220, 38, 38, 0.25)",
                    userSelect: "none",
                  }}
                >
                  <span style={{ fontSize: "9px" }}>손해사정사</span>
                  <span style={{ fontSize: "13px", letterSpacing: "1px" }}>{settings.name.slice(0, 3) || "손사"}</span>
                  <span style={{ fontSize: "9px" }}>[인]</span>
                </div>
              ) : (
                <div
                  style={{
                    width: "72px",
                    height: "72px",
                    border: "3px solid #dc2626",
                    borderRadius: "50%",
                    display: "flex",
                    flexDirection: "column",
                    justifyContent: "center",
                    alignItems: "center",
                    color: "#dc2626",
                    fontSize: "11px",
                    fontWeight: "bold",
                    lineHeight: "1.2",
                    transform: `rotate(${settings.stampRotation}deg)`,
                    boxShadow: "inset 0 0 4px rgba(220, 38, 38, 0.2)",
                    userSelect: "none",
                  }}
                >
                  <span>손해</span>
                  <span style={{ fontSize: "13px", letterSpacing: "1px" }}>{settings.name.slice(0, 3) || "사정사"}</span>
                  <span>[인]</span>
                </div>
              )}
            </div>

            <p style={{ margin: 0, fontSize: "12px", color: "#98a2b3" }}>
              인쇄 시 위와 같이 담당 손해사정사 서명란에 붉은색 인영이 날인됩니다.
            </p>
          </div>
        </div>
      </section>

      {/* Section 3: Report Standard Options */}
      <section className="card" style={{ marginBottom: "24px" }}>
        <h2 style={{ margin: "0 0 16px 0", fontSize: "18px", color: "#1d2939" }}>
          3. 보고서 양식 및 인쇄 기본값
        </h2>

        <div style={{ display: "grid", gap: "16px" }}>
          <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={settings.showStampByDefault}
              onChange={(e) => setSettings({ ...settings, showStampByDefault: e.target.checked })}
            />
            보고서 열람 시 직인을 기본으로 표시합니다.
          </label>

          <label style={{ display: "flex", alignItems: "center", gap: "8px", cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={settings.showWatermarkByDefault}
              onChange={(e) => setSettings({ ...settings, showWatermarkByDefault: e.target.checked })}
            />
            미종결 또는 심사 중인 보고서에 은은한 &quot;초안 (DRAFT)&quot; 워터마크를 기본 표시합니다.
          </label>

          <label>
            보고서 하단 표준 신의성실 / 법적 고지문구
            <textarea
              value={settings.noticeStatement}
              onChange={(e) => setSettings({ ...settings, noticeStatement: e.target.value })}
              rows={3}
              style={{ width: "100%", marginTop: "6px" }}
            />
          </label>
        </div>
      </section>

      {/* Bottom Actions */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <button
          type="button"
          onClick={handleReset}
          style={{ background: "#98a2b3", fontSize: "13px", padding: "10px 16px" }}
        >
          초기값으로 복원
        </button>

        <div style={{ display: "flex", gap: "10px" }}>
          <button
            type="button"
            onClick={handleSave}
            style={{
              padding: "12px 28px",
              background: "#155eef",
              color: "white",
              fontWeight: "bold",
              fontSize: "15px",
              borderRadius: "6px",
            }}
          >
            💾 설정 저장
          </button>
        </div>
      </div>
    </main>
  );
}
