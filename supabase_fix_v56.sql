-- v56: cho phép người đăng tải (Creator / Bbi share comm) tự tạo, sửa, xóa NHÓM CỦA CHÍNH MÌNH
-- Thay thế hoàn toàn file v55 (nếu đã chạy v55 thì cứ chạy file này, chạy lại nhiều lần vẫn an toàn).
-- Chạy trong Supabase → SQL Editor.

-- 1. Cột ghi nhận chủ sở hữu của từng nhóm
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. Điền sẵn owner_id cho nhóm cũ theo tên hiển thị (chỉ khi tên khớp đúng 1 người)
UPDATE public.categories c
SET owner_id = p.user_id
FROM public.creator_profiles p
WHERE c.owner_id IS NULL
  AND lower(trim(c.owner_name)) = lower(trim(p.display_name))
  AND (SELECT count(*) FROM public.creator_profiles p2
       WHERE lower(trim(p2.display_name)) = lower(trim(c.owner_name))) = 1;

-- 3. Trigger: khi người dùng (không phải Admin) tạo nhóm, server tự gán chủ sở hữu = chính họ
--    và ép owner_name = tên hiển thị của họ, nên không thể tạo nhóm đội tên người khác.
CREATE OR REPLACE FUNCTION public.categories_set_owner()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.app_admins a WHERE a.user_id = auth.uid()) THEN RETURN NEW; END IF;
  SELECT p.display_name INTO v_name FROM public.creator_profiles p WHERE p.user_id = auth.uid();
  NEW.owner_id := auth.uid();
  IF v_name IS NOT NULL AND length(trim(v_name)) > 0 THEN NEW.owner_name := trim(v_name); END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_categories_set_owner ON public.categories;
CREATE TRIGGER trg_categories_set_owner BEFORE INSERT ON public.categories
FOR EACH ROW EXECUTE FUNCTION public.categories_set_owner();

-- 4. Quyền
DROP POLICY IF EXISTS categories_owner_insert ON public.categories;
CREATE POLICY categories_owner_insert ON public.categories
FOR INSERT TO authenticated
WITH CHECK (
  owner_id = auth.uid()
  AND EXISTS (SELECT 1 FROM public.creator_profiles p WHERE p.user_id = auth.uid())
);

DROP POLICY IF EXISTS categories_owner_update ON public.categories;
CREATE POLICY categories_owner_update ON public.categories
FOR UPDATE TO authenticated
USING (
  owner_id = auth.uid()
  OR (owner_id IS NULL AND EXISTS (
        SELECT 1 FROM public.creator_profiles p
        WHERE p.user_id = auth.uid() AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
)
WITH CHECK (
  owner_id = auth.uid()
  OR (owner_id IS NULL AND EXISTS (
        SELECT 1 FROM public.creator_profiles p
        WHERE p.user_id = auth.uid() AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
);

DROP POLICY IF EXISTS categories_owner_delete ON public.categories;
CREATE POLICY categories_owner_delete ON public.categories
FOR DELETE TO authenticated
USING (
  owner_id = auth.uid()
  OR (owner_id IS NULL AND EXISTS (
        SELECT 1 FROM public.creator_profiles p
        WHERE p.user_id = auth.uid() AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
);

NOTIFY pgrst, 'reload schema';
