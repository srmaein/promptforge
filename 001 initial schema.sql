-- ============================================================
-- PromptForge — Initial Database Schema
-- Run in Supabase SQL Editor
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

-- ── Types ──────────────────────────────────────────────────
CREATE TYPE plan_type AS ENUM ('free', 'pro', 'team', 'enterprise');
CREATE TYPE subscription_status AS ENUM ('active', 'trialing', 'past_due', 'canceled', 'paused');

-- ── Users ──────────────────────────────────────────────────
CREATE TABLE public.users (
  id                     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email                  TEXT NOT NULL UNIQUE,
  full_name              TEXT,
  avatar_url             TEXT,
  plan                   plan_type NOT NULL DEFAULT 'free',
  subscription_status    subscription_status,
  stripe_customer_id     TEXT UNIQUE,
  stripe_subscription_id TEXT UNIQUE,
  referral_code          TEXT NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(6), 'hex'),
  referred_by            UUID REFERENCES public.users(id),
  referral_count         INT NOT NULL DEFAULT 0,
  onboarded_at           TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Prompt Optimizations ───────────────────────────────────
CREATE TABLE public.prompt_optimizations (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id          UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  original_prompt  TEXT NOT NULL,
  optimized_prompt TEXT NOT NULL,
  original_tokens  INT NOT NULL,
  optimized_tokens INT NOT NULL,
  savings_pct      NUMERIC(5,2) GENERATED ALWAYS AS (
    ROUND(((original_tokens - optimized_tokens)::NUMERIC / NULLIF(original_tokens, 0)) * 100, 2)
  ) STORED,
  target_model     TEXT NOT NULL DEFAULT 'general',
  quality_score    INT CHECK (quality_score BETWEEN 0 AND 100),
  structure_type   TEXT,
  share_id         TEXT UNIQUE,
  is_public        BOOLEAN NOT NULL DEFAULT FALSE,
  is_starred       BOOLEAN NOT NULL DEFAULT FALSE,
  title            TEXT,
  tags             TEXT[] DEFAULT '{}',
  metadata         JSONB DEFAULT '{}',
  embedding        VECTOR(1536),
  ip_address       INET,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Usage Records ──────────────────────────────────────────
CREATE TABLE public.usage_records (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id             UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  month_key           TEXT NOT NULL,
  optimizations_used  INT NOT NULL DEFAULT 0,
  optimizations_limit INT NOT NULL DEFAULT 25,
  tokens_processed    BIGINT NOT NULL DEFAULT 0,
  api_calls           INT NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, month_key)
);

-- ── Templates Marketplace ──────────────────────────────────
CREATE TABLE public.templates (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  author_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title         TEXT NOT NULL,
  description   TEXT NOT NULL,
  template_body TEXT NOT NULL,
  variables     JSONB DEFAULT '[]',
  category      TEXT NOT NULL DEFAULT 'general',
  target_models TEXT[] DEFAULT '{}',
  tags          TEXT[] DEFAULT '{}',
  is_published  BOOLEAN NOT NULL DEFAULT FALSE,
  is_featured   BOOLEAN NOT NULL DEFAULT FALSE,
  use_count     INT NOT NULL DEFAULT 0,
  like_count    INT NOT NULL DEFAULT 0,
  embedding     VECTOR(1536),
  slug          TEXT NOT NULL UNIQUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Referral Events ────────────────────────────────────────
CREATE TABLE public.referral_events (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  referrer_id     UUID NOT NULL REFERENCES public.users(id),
  referred_id     UUID NOT NULL REFERENCES public.users(id),
  reward_granted  BOOLEAN NOT NULL DEFAULT FALSE,
  reward_type     TEXT,
  reward_value    INT,
  triggered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Webhook Events (idempotency log) ───────────────────────
CREATE TABLE public.webhook_events (
  id           TEXT PRIMARY KEY,
  type         TEXT NOT NULL,
  processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  payload      JSONB NOT NULL
);

-- ── Indexes ────────────────────────────────────────────────
CREATE INDEX idx_opt_user_created ON prompt_optimizations(user_id, created_at DESC);
CREATE INDEX idx_opt_share ON prompt_optimizations(share_id) WHERE share_id IS NOT NULL;
CREATE INDEX idx_opt_public ON prompt_optimizations(is_public, created_at DESC) WHERE is_public = TRUE;
CREATE INDEX idx_opt_starred ON prompt_optimizations(user_id, is_starred) WHERE is_starred = TRUE;
CREATE INDEX idx_usage_user_month ON usage_records(user_id, month_key);
CREATE INDEX idx_tmpl_published ON templates(is_published, use_count DESC) WHERE is_published = TRUE;
CREATE INDEX idx_tmpl_category ON templates(category, use_count DESC);
CREATE INDEX idx_tmpl_author ON templates(author_id);
CREATE INDEX idx_tmpl_embedding ON templates USING ivfflat(embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX idx_referral_referrer ON referral_events(referrer_id);

-- ── Row Level Security ─────────────────────────────────────
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_optimizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;

-- Users
CREATE POLICY "users_self_all" ON public.users FOR ALL USING (auth.uid() = id);

-- Optimizations
CREATE POLICY "opt_own_all" ON public.prompt_optimizations FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "opt_public_read" ON public.prompt_optimizations
  FOR SELECT USING (is_public = true AND share_id IS NOT NULL);

-- Usage (read own, system writes)
CREATE POLICY "usage_own_read" ON public.usage_records FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "usage_service_all" ON public.usage_records FOR ALL USING (auth.role() = 'service_role');

-- Templates
CREATE POLICY "tmpl_public_read" ON public.templates FOR SELECT USING (is_published = true);
CREATE POLICY "tmpl_own_all" ON public.templates FOR ALL USING (auth.uid() = author_id);
CREATE POLICY "tmpl_service_all" ON public.templates FOR ALL USING (auth.role() = 'service_role');

-- Referral events (read own)
CREATE POLICY "ref_own_read" ON public.referral_events
  FOR SELECT USING (auth.uid() = referrer_id OR auth.uid() = referred_id);
CREATE POLICY "ref_service_all" ON public.referral_events FOR ALL USING (auth.role() = 'service_role');

-- Webhook events (service role only)
CREATE POLICY "webhook_service_all" ON public.webhook_events FOR ALL USING (auth.role() = 'service_role');

-- ── Triggers ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

CREATE TRIGGER users_updated_at BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER usage_updated_at BEFORE UPDATE ON public.usage_records
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER templates_updated_at BEFORE UPDATE ON public.templates
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Auto-create user profile on signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.users (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'avatar_url'
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── Helper Functions ───────────────────────────────────────
CREATE OR REPLACE FUNCTION increment_usage(p_user_id UUID, p_month_key TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.usage_records (user_id, month_key, optimizations_used, optimizations_limit)
  VALUES (p_user_id, p_month_key, 1, 25)
  ON CONFLICT (user_id, month_key)
  DO UPDATE SET
    optimizations_used = usage_records.optimizations_used + 1,
    updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION increment_referral_count(p_user_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.users SET referral_count = referral_count + 1 WHERE id = p_user_id;
END;
$$;
