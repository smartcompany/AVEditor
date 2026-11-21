/**
 * EasyClip auto-renewable subscription detail config for ASC.
 *
 * Prices: monthly USA customer price; annual = 10× (≈ 2 months free).
 * Locales match the existing Plus copy style.
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../../..');
const ASSETS = path.join(ROOT, 'docs/store-assets');
const REVIEW = path.join(ASSETS, 'review');

function locs(tier, period) {
  const annual = period === 'annual';
  const label = {
    plus: 'Plus',
    pro: 'Pro',
    studio: 'Studio',
  }[tier];

  if (annual) {
    return {
      'en-US': {
        name: `EasyClip ${label} Yearly`,
        description: `Unlock ${label} effects · 2 months free`,
      },
      ko: {
        name: `EasyClip ${label} 연간`,
        description: `${label} 효과 잠금 해제 · 2개월분 할인`,
      },
      ja: {
        name: `EasyClip ${label} 年額`,
        description: `${label}効果解除・2ヶ月分お得`,
      },
      'zh-Hans': {
        name: `EasyClip ${label} 年度`,
        description: `解锁 ${label} 效果 · 相当于送2个月`,
      },
    };
  }

  return {
    'en-US': {
      name: `EasyClip ${label} Monthly`,
      description: `Unlock ${label} effects · Auto-renews monthly`,
    },
    ko: {
      name: `EasyClip ${label} 월간`,
      description: `${label} 효과 잠금 해제 · 매월 자동 갱신`,
    },
    ja: {
      name: `EasyClip ${label} 月額`,
      description: `${label}効果解除・毎月自動更新`,
    },
    'zh-Hans': {
      name: `EasyClip ${label} 月度`,
      description: `解锁 ${label} 效果 · 每月自动续订`,
    },
  };
}

function entry(tier, period, usaPrice) {
  const stem = `${tier}-${period}`;
  return {
    tier,
    period,
    usaPrice,
    localizations: locs(tier, period),
    promoImage: path.join(ASSETS, `${stem}-1024.png`),
    reviewScreenshot: path.join(REVIEW, `${stem}.jpg`),
  };
}

/** productId → detail config */
export const SUBSCRIPTIONS = {
  'com.smartcompany.aveditor.plus.monthly': entry('plus', 'monthly', '2.99'),
  'com.smartcompany.aveditor.plus.annual': entry('plus', 'annual', '29.99'),
  'com.smartcompany.aveditor.pro.monthly': entry('pro', 'monthly', '6.99'),
  'com.smartcompany.aveditor.pro.annual': entry('pro', 'annual', '69.99'),
  'com.smartcompany.aveditor.studio.monthly': entry('studio', 'monthly', '9.99'),
  'com.smartcompany.aveditor.studio.annual': entry('studio', 'annual', '99.99'),
};

export const BASE_TERRITORY = 'USA';
export const PLAN_TYPE = 'UPFRONT';

/**
 * Subscription group “표시 이름 및 설명” (ASC subscriptionGroupLocalizations).
 * `name` = group display name; `customAppName` matches store listing app name.
 */
export const SUBSCRIPTION_GROUP_LOCALIZATIONS = {
  'en-US': {
    name: 'EasyClip Subscription',
    customAppName: 'EasyClip - Easy Shorts Editor',
  },
  ko: {
    name: 'EasyClip 구독',
    customAppName: 'EasyClip - 쉬운 숏폼 편집',
  },
  ja: {
    name: 'EasyClip サブスクリプション',
    customAppName: 'EasyClip - かんたんショート編集',
  },
  'zh-Hans': {
    name: 'EasyClip 订阅',
    customAppName: 'EasyClip - 轻松短视频剪辑',
  },
};

/**
 * One shared retention message for all paid tiers (app max 10; 1 per subscription).
 * header ≤66 chars, body ≤144 chars.
 */
export const RETENTION_MESSAGE = {
  referenceName: 'easyclip-keep-benefits',
  localizations: {
    'en-US': {
      header: 'Keep your benefits?',
      body: 'Stay subscribed to keep your unlocked effects and features.',
    },
    ko: {
      header: '혜택을 그대로 유지할까요?',
      body: '잠금 해제한 효과와 기능을 계속 쓰려면 구독을 유지해 주세요.',
    },
    ja: {
      header: '特典をそのまま残しますか？',
      body: '解除した効果や機能を続けるなら、登録を維持してください。',
    },
    'zh-Hans': {
      header: '要继续保留权益吗？',
      body: '继续订阅即可继续使用已解锁的效果与功能。',
    },
  },
};
