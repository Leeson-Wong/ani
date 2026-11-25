/** 动态 JSON 的安全取值辅助(上游番茄/CMS 响应字段可能缺失或类型漂移) */

export function jStr(obj: Record<string, Object> | undefined, key: string): string {
  if (obj === undefined) {
    return '';
  }
  const v = obj[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return `${v}`;
  }
  return '';
}

export function jNum(obj: Record<string, Object> | undefined, key: string, fallback: number = 0): number {
  if (obj === undefined) {
    return fallback;
  }
  const v = obj[key];
  if (typeof v === 'number') {
    return v;
  }
  if (typeof v === 'string') {
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  }
  return fallback;
}

export function jObj(obj: Record<string, Object> | undefined, key: string): Record<string, Object> | undefined {
  if (obj === undefined) {
    return undefined;
  }
  const v = obj[key];
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  return undefined;
}

export function jArr(obj: Record<string, Object> | undefined, key: string): Object[] {
  if (obj === undefined) {
    return [];
  }
  const v = obj[key];
  if (Array.isArray(v)) {
    return v;
  }
  return [];
}

export function asObj(v: Object): Record<string, Object> | undefined {
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  return undefined;
}
