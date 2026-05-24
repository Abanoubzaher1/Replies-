-- ReplyGenie AI Database Schema

-- 1. Users / Profiles Table (Hooks into Supabase Auth)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    full_name TEXT,
    avatar_url TEXT,
    role TEXT DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for Profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public read-access to profiles" ON public.profiles
    FOR SELECT USING (true);

CREATE POLICY "Allow individual update of own profile" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- 2. Subscriptions Table
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plan_type TEXT DEFAULT 'free' CHECK (plan_type IN ('free', 'pro', 'business')),
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'canceled', 'past_due')),
    current_period_end TIMESTAMP WITH TIME ZONE DEFAULT (timezone('utc'::text, now()) + interval '1 month') NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to view own subscription" ON public.subscriptions
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Allow system/admin modification of subscriptions" ON public.subscriptions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.profiles 
            WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
        )
    );

-- 3. Connected Pages Table (Facebook & Instagram API integrations)
CREATE TABLE IF NOT EXISTS public.connected_pages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('facebook', 'instagram')),
    page_name TEXT NOT NULL,
    page_id TEXT NOT NULL UNIQUE,
    access_token TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.connected_pages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to manage own connected pages" ON public.connected_pages
    FOR ALL USING (auth.uid() = user_id);

-- 4. Settings / Business Knowledge Base Table
CREATE TABLE IF NOT EXISTS public.settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    
    -- AI Tone settings
    tone_of_voice TEXT DEFAULT 'professional' CHECK (tone_of_voice IN ('professional', 'funny', 'friendly', 'luxury', 'helpful')),
    language TEXT DEFAULT 'english',
    egyptian_dialect_mode BOOLEAN DEFAULT false,
    professional_mode BOOLEAN DEFAULT true,
    funny_mode BOOLEAN DEFAULT false,
    luxury_brand_mode BOOLEAN DEFAULT false,
    
    -- Business Knowledge base
    business_name TEXT DEFAULT '',
    business_description TEXT DEFAULT '',
    products TEXT DEFAULT '',
    faqs TEXT DEFAULT '',
    prices TEXT DEFAULT '',
    working_hours TEXT DEFAULT '',
    delivery_areas TEXT DEFAULT '',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to manage own settings" ON public.settings
    FOR ALL USING (auth.uid() = user_id);

-- 5. Comments Table
CREATE TABLE IF NOT EXISTS public.comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    page_id UUID NOT NULL REFERENCES public.connected_pages(id) ON DELETE CASCADE,
    post_id TEXT NOT NULL,
    comment_id TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL,
    text TEXT NOT NULL,
    is_lead BOOLEAN DEFAULT false,
    buying_intent_score INTEGER DEFAULT 0 CHECK (buying_intent_score BETWEEN 0 AND 100),
    platform TEXT NOT NULL CHECK (platform IN ('facebook', 'instagram')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow user to access comments on connected pages" ON public.comments
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.connected_pages
            WHERE connected_pages.id = comments.page_id AND connected_pages.user_id = auth.uid()
        )
    );

-- 6. AI Replies Table
CREATE TABLE IF NOT EXISTS public.ai_replies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    comment_id UUID NOT NULL REFERENCES public.comments(id) ON DELETE CASCADE,
    reply_text TEXT NOT NULL,
    status TEXT DEFAULT 'pending_approval' CHECK (status IN ('pending_approval', 'approved', 'rejected', 'sent')),
    tone_used TEXT,
    model_version TEXT DEFAULT 'gemini-2.5-flash',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.ai_replies ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow user to manage replies to their comments" ON public.ai_replies
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.comments
            JOIN public.connected_pages ON comments.page_id = connected_pages.id
            WHERE comments.id = ai_replies.comment_id AND connected_pages.user_id = auth.uid()
        )
    );

-- 7. Leads Table (Automatically detected buying intent)
CREATE TABLE IF NOT EXISTS public.leads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    comment_id UUID NOT NULL REFERENCES public.comments(id) ON DELETE CASCADE,
    contact_name TEXT NOT NULL,
    message TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('facebook', 'instagram')),
    status TEXT DEFAULT 'new' CHECK (status IN ('new', 'contacted', 'closed')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow users to manage own leads" ON public.leads
    FOR ALL USING (auth.uid() = user_id);

-- Profile Sync Trigger
-- Setup automatically syncs new auth.users with public.profiles
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name, avatar_url)
    VALUES (
        new.id,
        new.email,
        new.raw_user_meta_data->>'full_name',
        new.raw_user_meta_data->>'avatar_url'
    );
    
    -- Create default settings for user
    INSERT INTO public.settings (user_id)
    VALUES (new.id);

    -- Create default free subscription
    INSERT INTO public.subscriptions (user_id, plan_type, status)
    VALUES (new.id, 'free', 'active');
    
    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
