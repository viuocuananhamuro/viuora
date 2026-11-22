-- v55: cho phép người đăng tải (Creator / Bbi share comm) tự tạo, sửa, xóa NHÓM CỦA CHÍNH MÌNH
-- Chạy file này trong Supabase → SQL Editor (chạy lại nhiều lần vẫn an toàn).

-- 1. Cột ghi nhận chủ sở hữu của từng nhóm
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2. Điền sẵn owner_id cho các nhóm cũ dựa theo tên hiển thị (chỉ khi tên khớp đúng 1 người)
UPDATE public.categories c
SET owner_id = p.user_id
FROM public.creator_profiles p
WHERE c.owner_id IS NULL
  AND lower(trim(c.owner_name)) = lower(trim(p.display_name))
  AND (SELECT count(*) FROM public.creator_profiles p2
       WHERE lower(trim(p2.display_name)) = lower(trim(c.owner_name))) = 1;

-- 3. Quyền: mỗi người chỉ thêm / sửa / xóa nhóm thuộc về mình (Admin vẫn dùng policy sẵn có)
DROP POLICY IF EXISTS categories_owner_insert ON public.categories;
CREATE POLICY categories_owner_insert ON public.categories
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.creator_profiles p
    WHERE p.user_id = auth.uid()
      AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))
      AND ((categories.section = 'creator' AND p.can_creator) OR (categories.section = 'commission' AND p.can_commission))
  )
  AND (categories.owner_id IS NULL OR categories.owner_id = auth.uid())
);

DROP POLICY IF EXISTS categories_owner_update ON public.categories;
CREATE POLICY categories_owner_update ON public.categories
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.creator_profiles p
    WHERE p.user_id = auth.uid()
      AND ((categories.section = 'creator' AND p.can_creator) OR (categories.section = 'commission' AND p.can_commission))
      AND (categories.owner_id = auth.uid()
           OR (categories.owner_id IS NULL AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
  )
)
WITH CHECK (
  categories.owner_id = auth.uid()
  OR (categories.owner_id IS NULL AND EXISTS (
        SELECT 1 FROM public.creator_profiles p
        WHERE p.user_id = auth.uid() AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
);

DROP POLICY IF EXISTS categories_owner_delete ON public.categories;
CREATE POLICY categories_owner_delete ON public.categories
FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.creator_profiles p
    WHERE p.user_id = auth.uid()
      AND (categories.owner_id = auth.uid()
           OR (categories.owner_id IS NULL AND lower(trim(p.display_name)) = lower(trim(categories.owner_name))))
  )
);

NOTIFY pgrst, 'reload schema';
